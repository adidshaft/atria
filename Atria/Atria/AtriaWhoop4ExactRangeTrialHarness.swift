import CryptoKit
import Darwin
import Foundation

/// Durable, research-only coordinator for one isolated WHOOP 4 exact-range
/// hypothesis trial.
///
/// This type deliberately has no CoreBluetooth dependency and is not wired to
/// `AtriaBLEManager`. It can issue only two transport instructions: one
/// `GET_CLOCK` (`0x0b`) and, after that exact response is bound, one
/// `GET_HISTORICAL_DATA` (`0x16`) whose data is exactly
/// `startUnixLE32 + endUnixLE32`. It has no sweep, alternate payload, retry, or
/// production-authority API.
///
/// All accepted evidence is journaled with an atomic file replacement and
/// directory fsync. In particular, a HISTORY_END ACK permit is returned only
/// after every observed `0x2f` frame has an externally supplied raw+identity
/// durability seal and the permit itself has survived a durable reread.
final class AtriaWhoop4ExactRangeTrialHarness: @unchecked Sendable {
    nonisolated static let productionIntegrationEnabled = false
    nonisolated static let requiredAcknowledgement =
        "WHOOP4_EXACT_RANGE_ONE_SHOT_RESEARCH_ONLY"
    nonisolated static let maximumIntervalSeconds: UInt32 = 15 * 60

    struct ResearchGate: Equatable, Sendable {
        fileprivate let acknowledgementSHA256: String

        init?(enabled: Bool, acknowledgement: String) {
            guard enabled,
                  acknowledgement == AtriaWhoop4ExactRangeTrialHarness
                    .requiredAcknowledgement else { return nil }
            acknowledgementSHA256 = Self.sha256(acknowledgement)
        }

        private static func sha256(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    struct ArmRequest: Equatable, Sendable {
        let transportGeneration: UInt64
        let peripheralIdentifier: String
        let strapIdentity: String
        let clockRequestSequence: UInt8
        let historyRequestSequence: UInt8
        let startUnix: UInt32
        let endUnix: UInt32
        /// Digest of the existing durable source interval selected for this
        /// non-destructive research trial.
        let sourceIntervalDurabilitySHA256: String
    }

    struct EventIdentity: Equatable, Sendable {
        let trialIdentifier: String
        let transportGeneration: UInt64
        let peripheralIdentifier: String
        let strapIdentity: String
    }

    struct CommandInstruction: Codable, Equatable, Sendable {
        let requestSequence: UInt8
        let command: UInt8
        let data: [UInt8]

        /// Inner WHOOP command packet before outer framing/CRC.
        var innerPacket: [UInt8] { [0x23, requestSequence, command] + data }
    }

    struct IssuedTrial: Equatable, Sendable {
        let identity: EventIdentity
        let getClock: CommandInstruction
    }

    struct WriteCompletion: Codable, Equatable, Sendable {
        let requestSequence: UInt8
        let command: UInt8
        let dataSHA256: String
        let innerPacketSHA256: String
        let completedAtUnix: TimeInterval
    }

    struct ClockResponseEvidence: Codable, Equatable, Sendable {
        let responseBytes: [UInt8]
        let responseSequence: UInt8
        let requestSequenceEcho: UInt8
        let deviceUnix: UInt32
        let receivedAtUnix: TimeInterval
    }

    struct HistoryResponseEvidence: Codable, Equatable, Sendable {
        let responseBytes: [UInt8]
        let responseSequence: UInt8
        let requestSequenceEcho: UInt8
        let receivedAtUnix: TimeInterval
    }

    struct HistoryStartEvidence: Codable, Equatable, Sendable {
        let metadataBytes: [UInt8]
        let metadataSequence: UInt8
        let deviceUnix: UInt32
        let receivedAtUnix: TimeInterval
    }

    struct RecordDurability: Codable, Equatable, Sendable {
        let payloadSHA256: String
        let rawSnapshotSHA256: String
        let identitySnapshotSHA256: String
        let rawDurableSequence: UInt64
        let identityDurableSequence: UInt64
        let fsyncedAtUnix: TimeInterval
    }

    struct RecordEvidence: Codable, Equatable, Sendable {
        let frameIdentifier: String
        let payloadSHA256: String
        let decodedRowTimestampsUnix: [UInt32]
        let allRowsDecoded: Bool
        let receivedAtUnix: TimeInterval
        var durability: RecordDurability?

        var usableRowCount: Int { decodedRowTimestampsUnix.count }
    }

    struct DurableFence: Codable, Equatable, Sendable {
        let rawSnapshotSHA256: String
        let identitySnapshotSHA256: String
        let rawDurableSequence: UInt64
        let identityDurableSequence: UInt64
        let fsyncedAtUnix: TimeInterval
    }

    struct ACKPermit: Codable, Equatable, Sendable {
        let trialIdentifier: String
        let boundaryIdentifier: String
        let expectedCommand: UInt8
        let expectedData: [UInt8]
        let evidenceSHA256: String
    }

    struct ACKWriteCompletion: Codable, Equatable, Sendable {
        let commandSequence: UInt8
        let command: UInt8
        let dataSHA256: String
        let innerPacketSHA256: String
        let completedAtUnix: TimeInterval
    }

    struct BatchBoundary: Codable, Equatable, Sendable {
        let boundaryIdentifier: String
        let metadataSHA256: String
        let metadataSequence: UInt8
        let sealedRecordCount: Int
        let fence: DurableFence
        let expectedACKData: [UInt8]
        let evidenceSHA256: String
        var ackWriteCompletion: ACKWriteCompletion?
    }

    struct CompletionEvidence: Codable, Equatable, Sendable {
        let metadataSHA256: String
        let metadataSequence: UInt8
        let fence: DurableFence
        let receivedAtUnix: TimeInterval
    }

    struct ValidatedResearchEvidence: Equatable, Sendable {
        let trialIdentifier: String
        let transportGeneration: UInt64
        let peripheralIdentifier: String
        let strapIdentity: String
        let startUnix: UInt32
        let endUnix: UInt32
        let clockRequestSequence: UInt8
        let historyRequestSequence: UInt8
        let clockDeviceUnix: UInt32
        let historyStartDeviceUnix: UInt32
        let durableRecordCount: Int
        let usableRowCount: Int
        let acknowledgedBoundaryCount: Int

        /// A positive trial remains research evidence until separately reviewed
        /// and deliberately integrated. This harness can never promote it.
        let authorizesProductionTransport = false
    }

    enum Rejection: String, Codable, Equatable, Sendable {
        case malformedClockResponse
        case malformedHistoryResponse
        case malformedHistoryStart
        case clockBindingMismatch
        case malformedHistoricalRecord
        case incompleteRecordDecode
        case outOfWindowRecord
        case conflictingRecord
        case recordBeforeACKCompletion
        case malformedHistoryEnd
        case ackPayloadMismatch
        case malformedHistoryComplete
    }

    enum HarnessError: Error, Equatable {
        case gateRequired
        case invalidRequest
        case trialAlreadyExists
        case stateCorrupt
        case trialMissing
        case staleEventIdentity
        case invalidPhase
        case commandMismatch
        case writeAlreadyCompleted
        case instructionAlreadyIssued
        case frameMissing
        case durabilityMismatch
        case recordsNotDurable
        case boundaryPendingACK
        case staleACKPermit
        case noUsableRows
        case terminalState(Rejection)
        case invalidEventTime
    }

    private struct StoredRequest: Codable, Equatable {
        let transportGeneration: UInt64
        let peripheralIdentifier: String
        let strapIdentity: String
        let clockRequestSequence: UInt8
        let historyRequestSequence: UInt8
        let startUnix: UInt32
        let endUnix: UInt32
        let sourceIntervalDurabilitySHA256: String
    }

    private struct Trial: Codable, Equatable {
        static let currentVersion = 1

        let version: Int
        let trialIdentifier: String
        let gateAcknowledgementSHA256: String
        let request: StoredRequest
        let armedAtUnix: TimeInterval
        let clockInstruction: CommandInstruction
        let historyInstruction: CommandInstruction
        var clockWriteCompletion: WriteCompletion?
        var clockResponse: ClockResponseEvidence?
        var historyInstructionIssuedAtUnix: TimeInterval?
        var historyWriteCompletion: WriteCompletion?
        var historyResponse: HistoryResponseEvidence?
        var historyStart: HistoryStartEvidence?
        var records: [RecordEvidence]
        var boundaries: [BatchBoundary]
        var completion: CompletionEvidence?
        var rejection: Rejection?
    }

    private struct Envelope: Codable, Equatable {
        static let currentVersion = 1
        let version: Int
        var trial: Trial?
    }

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let makeIdentifier: () -> String
    private let lock = NSLock()

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        makeIdentifier: @escaping () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent(
            "whoop4-exact-range-research-trial-v1.json"
        )
        self.fileManager = fileManager
        self.makeIdentifier = makeIdentifier
    }

    /// Durably consumes the sole trial slot and returns only the GET_CLOCK
    /// instruction. A second arm is never accepted, including after rejection
    /// or successful completion.
    func arm(
        gate: ResearchGate?,
        request: ArmRequest,
        now: Date
    ) throws -> IssuedTrial {
        guard let gate else { throw HarnessError.gateRequired }
        try Self.validate(request, now: now)
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        guard envelope.trial == nil else { throw HarnessError.trialAlreadyExists }
        let identifier = makeIdentifier()
        guard !identifier.isEmpty else { throw HarnessError.invalidRequest }
        let stored = StoredRequest(
            transportGeneration: request.transportGeneration,
            peripheralIdentifier: request.peripheralIdentifier,
            strapIdentity: request.strapIdentity,
            clockRequestSequence: request.clockRequestSequence,
            historyRequestSequence: request.historyRequestSequence,
            startUnix: request.startUnix,
            endUnix: request.endUnix,
            sourceIntervalDurabilitySHA256:
                request.sourceIntervalDurabilitySHA256
        )
        let clock = CommandInstruction(
            requestSequence: request.clockRequestSequence,
            command: 0x0b,
            data: []
        )
        let history = CommandInstruction(
            requestSequence: request.historyRequestSequence,
            command: 0x16,
            data: Self.le32(request.startUnix) + Self.le32(request.endUnix)
        )
        let trial = Trial(
            version: Trial.currentVersion,
            trialIdentifier: identifier,
            gateAcknowledgementSHA256: gate.acknowledgementSHA256,
            request: stored,
            armedAtUnix: now.timeIntervalSince1970,
            clockInstruction: clock,
            historyInstruction: history,
            clockWriteCompletion: nil,
            clockResponse: nil,
            historyInstructionIssuedAtUnix: nil,
            historyWriteCompletion: nil,
            historyResponse: nil,
            historyStart: nil,
            records: [],
            boundaries: [],
            completion: nil,
            rejection: nil
        )
        envelope.trial = trial
        try persistLocked(envelope)
        let persisted = try Self.requireTrial(try loadLocked())
        guard persisted == trial else { throw HarnessError.stateCorrupt }
        return IssuedTrial(
            identity: Self.identity(for: persisted),
            getClock: persisted.clockInstruction
        )
    }

    func recordGETClockWriteCompleted(
        identity: EventIdentity,
        instruction: CommandInstruction,
        completedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard instruction == trial.clockInstruction else {
                throw HarnessError.commandMismatch
            }
            guard trial.clockWriteCompletion == nil else {
                throw HarnessError.writeAlreadyCompleted
            }
            try Self.requireTime(
                completedAt,
                atLeast: trial.armedAtUnix
            )
            trial.clockWriteCompletion = Self.writeEvidence(
                instruction,
                completedAt: completedAt
            )
        }
    }

    /// Records the matching GET_CLOCK response and durably issues the one and
    /// only exact-range instruction. If persistence succeeds but the caller
    /// crashes before receiving the return value, the instruction is not
    /// reissued: uncertainty fails closed instead of risking a second attempt.
    func recordGETClockResponseAndIssueExactRange(
        identity: EventIdentity,
        responseBytes: [UInt8],
        receivedAt: Date
    ) throws -> CommandInstruction {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var trial = try Self.requireTrial(envelope)
        try Self.match(identity, trial: trial)
        try Self.requireLive(trial)
        guard let clockWrite = trial.clockWriteCompletion,
              trial.clockResponse == nil,
              trial.historyInstructionIssuedAtUnix == nil else {
            throw HarnessError.instructionAlreadyIssued
        }
        do {
            let response = try AtriaWhoop4HistoryResearchProtocol
                .parseClockObservation(responseBytes)
            guard response.requestSequenceEcho
                    == trial.request.clockRequestSequence,
                  response.observedPrefix == 0x01,
                  (1_500_000_000...2_200_000_000)
                    .contains(response.deviceUnix) else {
                throw HarnessError.commandMismatch
            }
            try Self.requireTime(receivedAt, atLeast: clockWrite.completedAtUnix)
            trial.clockResponse = ClockResponseEvidence(
                responseBytes: responseBytes,
                responseSequence: response.responseSequence,
                requestSequenceEcho: response.requestSequenceEcho,
                deviceUnix: response.deviceUnix,
                receivedAtUnix: receivedAt.timeIntervalSince1970
            )
            trial.historyInstructionIssuedAtUnix = receivedAt.timeIntervalSince1970
        } catch let error as HarnessError {
            trial.rejection = .malformedClockResponse
            envelope.trial = trial
            try persistLocked(envelope)
            throw error
        } catch {
            trial.rejection = .malformedClockResponse
            envelope.trial = trial
            try persistLocked(envelope)
            throw HarnessError.terminalState(.malformedClockResponse)
        }
        envelope.trial = trial
        try persistLocked(envelope)
        let persisted = try Self.requireTrial(try loadLocked())
        guard persisted == trial else { throw HarnessError.stateCorrupt }
        return trial.historyInstruction
    }

    func recordExactRangeWriteCompleted(
        identity: EventIdentity,
        instruction: CommandInstruction,
        completedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard trial.clockResponse != nil,
                  let issuedAt = trial.historyInstructionIssuedAtUnix else {
                throw HarnessError.invalidPhase
            }
            guard instruction == trial.historyInstruction,
                  instruction.command == 0x16,
                  instruction.data.count == 8 else {
                throw HarnessError.commandMismatch
            }
            guard trial.historyWriteCompletion == nil else {
                throw HarnessError.writeAlreadyCompleted
            }
            try Self.requireTime(completedAt, atLeast: issuedAt)
            trial.historyWriteCompletion = Self.writeEvidence(
                instruction,
                completedAt: completedAt
            )
        }
    }

    func recordExactRangeCommandResponse(
        identity: EventIdentity,
        responseBytes: [UInt8],
        receivedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard let write = trial.historyWriteCompletion,
                  trial.historyResponse == nil else {
                throw HarnessError.invalidPhase
            }
            do {
                let response = try AtriaWhoop4HistoryResearchProtocol
                    .parseCommandResponse(responseBytes)
                guard response.commandEcho == 0x16,
                      response.requestSequenceEcho
                        == trial.request.historyRequestSequence else {
                    throw HarnessError.commandMismatch
                }
                try Self.requireTime(receivedAt, atLeast: write.completedAtUnix)
                guard receivedAt.timeIntervalSince1970
                        - write.completedAtUnix <= 30 else {
                    throw HarnessError.invalidEventTime
                }
                trial.historyResponse = HistoryResponseEvidence(
                    responseBytes: responseBytes,
                    responseSequence: response.responseSequence,
                    requestSequenceEcho: response.requestSequenceEcho,
                    receivedAtUnix: receivedAt.timeIntervalSince1970
                )
                try Self.validateClockBindingIfComplete(&trial)
            } catch let error as HarnessError {
                trial.rejection = error == .commandMismatch
                    ? .malformedHistoryResponse : .clockBindingMismatch
                throw error
            } catch {
                trial.rejection = .malformedHistoryResponse
                throw HarnessError.terminalState(.malformedHistoryResponse)
            }
        }
    }

    func recordHistoryStart(
        identity: EventIdentity,
        metadataBytes: [UInt8],
        receivedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard let write = trial.historyWriteCompletion,
                  trial.historyStart == nil else {
                throw HarnessError.invalidPhase
            }
            do {
                let start = try AtriaWhoop4HistoryResearchProtocol
                    .parseHistoryStartClockObservation(metadataBytes)
                try Self.requireTime(receivedAt, atLeast: write.completedAtUnix)
                guard receivedAt.timeIntervalSince1970
                        - write.completedAtUnix <= 30 else {
                    throw HarnessError.invalidEventTime
                }
                trial.historyStart = HistoryStartEvidence(
                    metadataBytes: metadataBytes,
                    metadataSequence: start.metadataSequence,
                    deviceUnix: start.deviceUnix,
                    receivedAtUnix: receivedAt.timeIntervalSince1970
                )
                try Self.validateClockBindingIfComplete(&trial)
            } catch let error as HarnessError {
                trial.rejection = .clockBindingMismatch
                throw error
            } catch {
                trial.rejection = .malformedHistoryStart
                throw HarnessError.terminalState(.malformedHistoryStart)
            }
        }
    }

    /// Journals the arrival of one complete decoded `0x2f` record before any
    /// ACK can be authorized. The caller must explicitly attest that every row
    /// in the payload was decoded; partial decode permanently rejects the
    /// trial. Every decoded timestamp must be inside the requested interval.
    func recordObservedHistoricalRecord(
        identity: EventIdentity,
        frameIdentifier: String,
        payload: [UInt8],
        decodedRowTimestampsUnix: [UInt32],
        allRowsDecoded: Bool,
        receivedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard Self.hasBoundStart(trial) else {
                throw HarnessError.invalidPhase
            }
            guard trial.boundaries.last?.ackWriteCompletion != nil
                    || trial.boundaries.isEmpty else {
                trial.rejection = .recordBeforeACKCompletion
                throw HarnessError.terminalState(.recordBeforeACKCompletion)
            }
            guard !frameIdentifier.isEmpty,
                  payload.first == 0x2f,
                  payload.count > 1 else {
                trial.rejection = .malformedHistoricalRecord
                throw HarnessError.terminalState(.malformedHistoricalRecord)
            }
            guard allRowsDecoded else {
                trial.rejection = .incompleteRecordDecode
                throw HarnessError.terminalState(.incompleteRecordDecode)
            }
            guard decodedRowTimestampsUnix.allSatisfy({ timestamp in
                timestamp >= trial.request.startUnix
                    && timestamp <= trial.request.endUnix
            }) else {
                trial.rejection = .outOfWindowRecord
                throw HarnessError.terminalState(.outOfWindowRecord)
            }
            let evidence = RecordEvidence(
                frameIdentifier: frameIdentifier,
                payloadSHA256: Self.sha256(Data(payload)),
                decodedRowTimestampsUnix: decodedRowTimestampsUnix,
                allRowsDecoded: true,
                receivedAtUnix: receivedAt.timeIntervalSince1970,
                durability: nil
            )
            if let existing = trial.records.first(where: {
                $0.frameIdentifier == frameIdentifier
            }) {
                guard existing == evidence || Self.sameObservedRecord(existing, evidence) else {
                    trial.rejection = .conflictingRecord
                    throw HarnessError.terminalState(.conflictingRecord)
                }
                return
            }
            let lowerBound = max(
                trial.historyResponse?.receivedAtUnix ?? 0,
                trial.historyStart?.receivedAtUnix ?? 0
            )
            try Self.requireTime(receivedAt, atLeast: lowerBound)
            trial.records.append(evidence)
        }
    }

    func recordHistoricalRecordFsynced(
        identity: EventIdentity,
        frameIdentifier: String,
        durability: RecordDurability
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard let index = trial.records.firstIndex(where: {
                $0.frameIdentifier == frameIdentifier
            }) else { throw HarnessError.frameMissing }
            let record = trial.records[index]
            guard durability.payloadSHA256 == record.payloadSHA256,
                  Self.isSHA256(durability.rawSnapshotSHA256),
                  Self.isSHA256(durability.identitySnapshotSHA256),
                  durability.rawDurableSequence > 0,
                  durability.identityDurableSequence > 0,
                  durability.fsyncedAtUnix.isFinite,
                  durability.fsyncedAtUnix >= record.receivedAtUnix else {
                throw HarnessError.durabilityMismatch
            }
            if let existing = record.durability {
                guard existing == durability else {
                    throw HarnessError.durabilityMismatch
                }
                return
            }
            trial.records[index].durability = durability
        }
    }

    /// Persists a HISTORY_END boundary and returns the only ACK bytes that may
    /// be written. No permit is produced while any observed frame lacks its
    /// durable raw+identity receipt.
    func recordHistoryEndAndCreateACKPermit(
        identity: EventIdentity,
        boundaryIdentifier: String,
        metadataBytes: [UInt8],
        fence: DurableFence
    ) throws -> ACKPermit {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var trial = try Self.requireTrial(envelope)
        try Self.match(identity, trial: trial)
        try Self.requireLive(trial)
        guard Self.hasBoundStart(trial) else { throw HarnessError.invalidPhase }
        guard !boundaryIdentifier.isEmpty else {
            throw HarnessError.commandMismatch
        }
        guard trial.boundaries.last?.ackWriteCompletion != nil
                || trial.boundaries.isEmpty else {
            throw HarnessError.boundaryPendingACK
        }
        guard trial.records.allSatisfy({ $0.durability != nil }) else {
            throw HarnessError.recordsNotDurable
        }
        let marker: AtriaWhoop4HistoryMetadata.Marker
        do {
            marker = try AtriaWhoop4HistoryMetadata.parse(metadataBytes)
        } catch {
            trial.rejection = .malformedHistoryEnd
            envelope.trial = trial
            try persistLocked(envelope)
            throw HarnessError.terminalState(.malformedHistoryEnd)
        }
        guard case .historyEnd(let sequence, _, let token) = marker else {
            trial.rejection = .malformedHistoryEnd
            envelope.trial = trial
            try persistLocked(envelope)
            throw HarnessError.terminalState(.malformedHistoryEnd)
        }
        try Self.validateFence(fence, records: trial.records, prior: trial.boundaries.last?.fence)
        guard !trial.boundaries.contains(where: {
            $0.boundaryIdentifier == boundaryIdentifier
        }) else { throw HarnessError.commandMismatch }
        let seed = BoundaryDigestSeed(
            trialIdentifier: trial.trialIdentifier,
            boundaryIdentifier: boundaryIdentifier,
            metadataSHA256: Self.sha256(Data(metadataBytes)),
            metadataSequence: sequence,
            sealedRecordCount: trial.records.count,
            fence: fence,
            expectedACKData: token.acknowledgementPayload
        )
        let evidenceSHA256 = try Self.canonicalSHA256(seed)
        let boundary = BatchBoundary(
            boundaryIdentifier: boundaryIdentifier,
            metadataSHA256: seed.metadataSHA256,
            metadataSequence: sequence,
            sealedRecordCount: trial.records.count,
            fence: fence,
            expectedACKData: token.acknowledgementPayload,
            evidenceSHA256: evidenceSHA256,
            ackWriteCompletion: nil
        )
        trial.boundaries.append(boundary)
        envelope.trial = trial
        try persistLocked(envelope)
        let persisted = try Self.requireTrial(try loadLocked())
        guard persisted == trial,
              persisted.boundaries.last == boundary else {
            throw HarnessError.stateCorrupt
        }
        return ACKPermit(
            trialIdentifier: trial.trialIdentifier,
            boundaryIdentifier: boundaryIdentifier,
            expectedCommand: 0x17,
            expectedData: token.acknowledgementPayload,
            evidenceSHA256: evidenceSHA256
        )
    }

    func recordACKWriteCompleted(
        identity: EventIdentity,
        permit: ACKPermit,
        commandSequence: UInt8,
        command: UInt8,
        data: [UInt8],
        completedAt: Date
    ) throws {
        try mutate(identity) { trial in
            try Self.requireLive(trial)
            guard permit.trialIdentifier == trial.trialIdentifier,
                  let index = trial.boundaries.firstIndex(where: {
                    $0.boundaryIdentifier == permit.boundaryIdentifier
                  }) else { throw HarnessError.staleACKPermit }
            let boundary = trial.boundaries[index]
            guard boundary.ackWriteCompletion == nil,
                  permit.evidenceSHA256 == boundary.evidenceSHA256,
                  permit.expectedCommand == 0x17,
                  permit.expectedData == boundary.expectedACKData else {
                throw HarnessError.staleACKPermit
            }
            guard command == permit.expectedCommand,
                  data == permit.expectedData else {
                trial.rejection = .ackPayloadMismatch
                throw HarnessError.terminalState(.ackPayloadMismatch)
            }
            try Self.requireTime(completedAt, atLeast: boundary.fence.fsyncedAtUnix)
            let instruction = CommandInstruction(
                requestSequence: commandSequence,
                command: command,
                data: data
            )
            trial.boundaries[index].ackWriteCompletion = ACKWriteCompletion(
                commandSequence: commandSequence,
                command: command,
                dataSHA256: Self.sha256(Data(data)),
                innerPacketSHA256: Self.sha256(Data(instruction.innerPacket)),
                completedAtUnix: completedAt.timeIntervalSince1970
            )
        }
    }

    /// Accepts HISTORY_COMPLETE only after all frames and ACKs are durable and
    /// at least one fully decoded usable row lies inside the requested range.
    /// The return type is explicitly non-production research evidence.
    func recordHistoryComplete(
        identity: EventIdentity,
        metadataBytes: [UInt8],
        terminalFence: DurableFence,
        receivedAt: Date
    ) throws -> ValidatedResearchEvidence {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var trial = try Self.requireTrial(envelope)
        try Self.match(identity, trial: trial)
        try Self.requireLive(trial)
        guard Self.hasBoundStart(trial), trial.completion == nil else {
            throw HarnessError.invalidPhase
        }
        guard trial.records.allSatisfy({ $0.durability != nil }) else {
            throw HarnessError.recordsNotDurable
        }
        guard trial.boundaries.allSatisfy({ $0.ackWriteCompletion != nil }) else {
            throw HarnessError.boundaryPendingACK
        }
        let usableRows = trial.records.reduce(0) { $0 + $1.usableRowCount }
        guard usableRows > 0 else { throw HarnessError.noUsableRows }
        let marker: AtriaWhoop4HistoryMetadata.Marker
        do {
            marker = try AtriaWhoop4HistoryMetadata.parse(metadataBytes)
        } catch {
            trial.rejection = .malformedHistoryComplete
            envelope.trial = trial
            try persistLocked(envelope)
            throw HarnessError.terminalState(.malformedHistoryComplete)
        }
        guard case .historyComplete(let sequence) = marker else {
            trial.rejection = .malformedHistoryComplete
            envelope.trial = trial
            try persistLocked(envelope)
            throw HarnessError.terminalState(.malformedHistoryComplete)
        }
        try Self.validateFence(
            terminalFence,
            records: trial.records,
            prior: trial.boundaries.last?.fence
        )
        let lowerTime = max(
            trial.records.compactMap { $0.durability?.fsyncedAtUnix }.max() ?? 0,
            trial.boundaries.compactMap {
                $0.ackWriteCompletion?.completedAtUnix
            }.max() ?? 0
        )
        try Self.requireTime(receivedAt, atLeast: max(lowerTime, terminalFence.fsyncedAtUnix))
        trial.completion = CompletionEvidence(
            metadataSHA256: Self.sha256(Data(metadataBytes)),
            metadataSequence: sequence,
            fence: terminalFence,
            receivedAtUnix: receivedAt.timeIntervalSince1970
        )
        envelope.trial = trial
        try persistLocked(envelope)
        let persisted = try Self.requireTrial(try loadLocked())
        guard persisted == trial else { throw HarnessError.stateCorrupt }
        return try Self.validatedEvidence(trial)
    }

    func loadValidatedEvidence() throws -> ValidatedResearchEvidence? {
        lock.lock()
        defer { lock.unlock() }
        let trial = try Self.requireTrial(try loadLocked())
        guard trial.completion != nil else { return nil }
        return try Self.validatedEvidence(trial)
    }

    func loadEventIdentity() throws -> EventIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let trial = try loadLocked().trial else { return nil }
        return Self.identity(for: trial)
    }

    // MARK: - Mutation and validation

    private func mutate(
        _ identity: EventIdentity,
        _ body: (inout Trial) throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var envelope = try loadLocked()
        var trial = try Self.requireTrial(envelope)
        try Self.match(identity, trial: trial)
        do {
            try body(&trial)
        } catch {
            envelope.trial = trial
            try persistLocked(envelope)
            throw error
        }
        envelope.trial = trial
        try persistLocked(envelope)
    }

    private static func validateClockBindingIfComplete(
        _ trial: inout Trial
    ) throws {
        guard let clock = trial.clockResponse,
              let history = trial.historyResponse,
              let start = trial.historyStart else { return }
        guard AtriaWhoop4HistoryResearchProtocol.bindAttemptClock(
            clockRequestSequence: trial.request.clockRequestSequence,
            historyRequestSequence: trial.request.historyRequestSequence,
            clockResponseBytes: clock.responseBytes,
            historyResponseBytes: history.responseBytes,
            historyStartBytes: start.metadataBytes,
            maximumClockAdvanceSeconds: 30
        ) != nil else {
            trial.rejection = .clockBindingMismatch
            throw HarnessError.terminalState(.clockBindingMismatch)
        }
    }

    private static func hasBoundStart(_ trial: Trial) -> Bool {
        guard trial.clockResponse != nil,
              trial.historyResponse != nil,
              trial.historyStart != nil else { return false }
        var copy = trial
        return (try? validateClockBindingIfComplete(&copy)) != nil
    }

    private static func validate(
        _ request: ArmRequest,
        now: Date
    ) throws {
        let duration = request.endUnix.subtractingReportingOverflow(
            request.startUnix
        )
        guard request.transportGeneration > 0,
              !request.peripheralIdentifier.isEmpty,
              !request.strapIdentity.isEmpty,
              request.clockRequestSequence != request.historyRequestSequence,
              !duration.overflow,
              duration.partialValue > 0,
              duration.partialValue <= maximumIntervalSeconds,
              isSHA256(request.sourceIntervalDurabilitySHA256),
              now.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970 >= TimeInterval(request.endUnix) else {
            throw HarnessError.invalidRequest
        }
    }

    private static func validateFence(
        _ fence: DurableFence,
        records: [RecordEvidence],
        prior: DurableFence?
    ) throws {
        guard isSHA256(fence.rawSnapshotSHA256),
              isSHA256(fence.identitySnapshotSHA256),
              fence.rawDurableSequence > 0,
              fence.identityDurableSequence > 0,
              fence.fsyncedAtUnix.isFinite,
              records.allSatisfy({ record in
                guard let durable = record.durability else { return false }
                return fence.rawDurableSequence >= durable.rawDurableSequence
                    && fence.identityDurableSequence
                        >= durable.identityDurableSequence
                    && fence.fsyncedAtUnix >= durable.fsyncedAtUnix
              }) else { throw HarnessError.recordsNotDurable }
        if let prior {
            guard fence.rawDurableSequence >= prior.rawDurableSequence,
                  fence.identityDurableSequence >= prior.identityDurableSequence,
                  fence.fsyncedAtUnix >= prior.fsyncedAtUnix else {
                throw HarnessError.durabilityMismatch
            }
        }
    }

    private static func requireLive(_ trial: Trial) throws {
        if let rejection = trial.rejection {
            throw HarnessError.terminalState(rejection)
        }
        guard trial.completion == nil else { throw HarnessError.invalidPhase }
    }

    private static func match(
        _ identity: EventIdentity,
        trial: Trial
    ) throws {
        guard identity == Self.identity(for: trial) else {
            throw HarnessError.staleEventIdentity
        }
    }

    private static func identity(for trial: Trial) -> EventIdentity {
        EventIdentity(
            trialIdentifier: trial.trialIdentifier,
            transportGeneration: trial.request.transportGeneration,
            peripheralIdentifier: trial.request.peripheralIdentifier,
            strapIdentity: trial.request.strapIdentity
        )
    }

    private static func requireTime(
        _ date: Date,
        atLeast lowerBound: TimeInterval
    ) throws {
        guard date.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970 >= lowerBound else {
            throw HarnessError.invalidEventTime
        }
    }

    private static func writeEvidence(
        _ instruction: CommandInstruction,
        completedAt: Date
    ) -> WriteCompletion {
        WriteCompletion(
            requestSequence: instruction.requestSequence,
            command: instruction.command,
            dataSHA256: sha256(Data(instruction.data)),
            innerPacketSHA256: sha256(Data(instruction.innerPacket)),
            completedAtUnix: completedAt.timeIntervalSince1970
        )
    }

    private static func sameObservedRecord(
        _ lhs: RecordEvidence,
        _ rhs: RecordEvidence
    ) -> Bool {
        lhs.frameIdentifier == rhs.frameIdentifier
            && lhs.payloadSHA256 == rhs.payloadSHA256
            && lhs.decodedRowTimestampsUnix == rhs.decodedRowTimestampsUnix
            && lhs.allRowsDecoded == rhs.allRowsDecoded
            && lhs.receivedAtUnix == rhs.receivedAtUnix
    }

    private static func validatedEvidence(
        _ trial: Trial
    ) throws -> ValidatedResearchEvidence {
        guard trial.rejection == nil,
              trial.completion != nil,
              let clock = trial.clockResponse,
              let start = trial.historyStart,
              hasBoundStart(trial),
              trial.records.allSatisfy({ $0.durability != nil }),
              trial.boundaries.allSatisfy({ $0.ackWriteCompletion != nil }) else {
            throw HarnessError.stateCorrupt
        }
        let usableRows = trial.records.reduce(0) { $0 + $1.usableRowCount }
        guard usableRows > 0 else { throw HarnessError.stateCorrupt }
        return ValidatedResearchEvidence(
            trialIdentifier: trial.trialIdentifier,
            transportGeneration: trial.request.transportGeneration,
            peripheralIdentifier: trial.request.peripheralIdentifier,
            strapIdentity: trial.request.strapIdentity,
            startUnix: trial.request.startUnix,
            endUnix: trial.request.endUnix,
            clockRequestSequence: trial.request.clockRequestSequence,
            historyRequestSequence: trial.request.historyRequestSequence,
            clockDeviceUnix: clock.deviceUnix,
            historyStartDeviceUnix: start.deviceUnix,
            durableRecordCount: trial.records.count,
            usableRowCount: usableRows,
            acknowledgedBoundaryCount: trial.boundaries.count
        )
    }

    // MARK: - Durable state

    private func loadLocked() throws -> Envelope {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return Envelope(version: Envelope.currentVersion, trial: nil)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let envelope = try Self.decoder.decode(Envelope.self, from: data)
            guard envelope.version == Envelope.currentVersion,
                  try Self.canonicalData(envelope) == data else {
                throw HarnessError.stateCorrupt
            }
            if let trial = envelope.trial { try Self.validateStored(trial) }
            return envelope
        } catch let error as HarnessError {
            throw error
        } catch {
            throw HarnessError.stateCorrupt
        }
    }

    private func persistLocked(_ envelope: Envelope) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try Self.canonicalData(envelope)
        let temporary = directoryURL.appendingPathComponent(
            ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: stateURL.path) {
            _ = try fileManager.replaceItemAt(
                stateURL,
                withItemAt: temporary
            )
        } else {
            try fileManager.moveItem(at: temporary, to: stateURL)
        }
        try Self.synchronizeDirectory(directoryURL)
    }

    private static func validateStored(_ trial: Trial) throws {
        guard trial.version == Trial.currentVersion,
              !trial.trialIdentifier.isEmpty,
              isSHA256(trial.gateAcknowledgementSHA256),
              isSHA256(trial.request.sourceIntervalDurabilitySHA256),
              trial.request.transportGeneration > 0,
              trial.request.endUnix > trial.request.startUnix,
              trial.request.endUnix - trial.request.startUnix
                <= maximumIntervalSeconds,
              trial.clockInstruction.command == 0x0b,
              trial.clockInstruction.requestSequence
                == trial.request.clockRequestSequence,
              trial.clockInstruction.data.isEmpty,
              trial.historyInstruction.command == 0x16,
              trial.historyInstruction.requestSequence
                == trial.request.historyRequestSequence,
              trial.historyInstruction.data
                == le32(trial.request.startUnix) + le32(trial.request.endUnix),
              trial.historyInstructionIssuedAtUnix != nil
                || (trial.historyWriteCompletion == nil
                    && trial.historyResponse == nil
                    && trial.historyStart == nil
                    && trial.records.isEmpty
                    && trial.boundaries.isEmpty
                    && trial.completion == nil),
              trial.records.allSatisfy({
                !$0.frameIdentifier.isEmpty
                    && isSHA256($0.payloadSHA256)
                    && $0.allRowsDecoded
                    && $0.decodedRowTimestampsUnix.allSatisfy({ timestamp in
                        timestamp >= trial.request.startUnix
                            && timestamp <= trial.request.endUnix
                    })
              }),
              Set(trial.records.map(\.frameIdentifier)).count
                == trial.records.count,
              Set(trial.boundaries.map(\.boundaryIdentifier)).count
                == trial.boundaries.count else {
            throw HarnessError.stateCorrupt
        }
        if trial.completion != nil {
            _ = try validatedEvidence(trial)
        }
    }

    private static func requireTrial(_ envelope: Envelope) throws -> Trial {
        guard let trial = envelope.trial else { throw HarnessError.trialMissing }
        return trial
    }

    private struct BoundaryDigestSeed: Codable {
        let trialIdentifier: String
        let boundaryIdentifier: String
        let metadataSHA256: String
        let metadataSequence: UInt8
        let sealedRecordCount: Int
        let fence: DurableFence
        let expectedACKData: [UInt8]
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    private static func canonicalSHA256<T: Encodable>(_ value: T) throws -> String {
        sha256(try canonicalData(value))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character)
        }
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ]
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
