import Foundation

/// Side-effect-free decoders for WHOOP 4 history fields that are useful to
/// protocol research but are not yet production transport authority.
///
/// Every field exposed here is either a literal byte slice or is named as an
/// observation. In particular, this type does not construct `0x21` read-pointer
/// payloads and does not claim that a `0x22` record is an exact range selector.
enum AtriaWhoop4HistoryResearchProtocol {
    static let commandResponsePacketType: UInt8 = 0x24
    static let metadataPacketType: UInt8 = 0x31

    enum ParseError: Error, Equatable, Sendable {
        case tooShort(actual: Int, required: Int)
        case unexpectedPacketType(UInt8)
        case unexpectedCommand(actual: UInt8, expected: UInt8)
        case unexpectedMetadataMarker(UInt8)
        case missingObservedDataRangeRecords(actualBodyBytes: Int)
    }

    /// Physical WHOOP 4 captures show that command responses have two distinct
    /// sequence values:
    ///
    /// `[0x24, responseSequence, commandEcho, requestSequenceEcho, data...]`
    ///
    /// For example, a sent `0x0b` request with sequence `0x04` produced
    /// `24 9f 0b 04 ...`, and a sent `0x16` request with sequence `0x05`
    /// produced `24 a0 16 05 ...`. Keeping both values prevents a response from
    /// being attributed to an attempt by arrival order alone.
    struct CommandResponseEnvelope: Equatable, Sendable {
        let responseSequence: UInt8
        let commandEcho: UInt8
        let requestSequenceEcho: UInt8
        let data: [UInt8]
    }

    static func parseCommandResponse(
        _ bytes: [UInt8]
    ) throws -> CommandResponseEnvelope {
        guard bytes.count >= 4 else {
            throw ParseError.tooShort(actual: bytes.count, required: 4)
        }
        guard bytes[0] == commandResponsePacketType else {
            throw ParseError.unexpectedPacketType(bytes[0])
        }
        return CommandResponseEnvelope(
            responseSequence: bytes[1],
            commandEcho: bytes[2],
            requestSequenceEcho: bytes[3],
            data: Array(bytes.dropFirst(4))
        )
    }

    /// Research interpretation of a physically captured `GET_CLOCK` (`0x0b`)
    /// response. `data[0] == 0x01` is an observed prefix, not a generalized
    /// success-code contract. The following four bytes repeatedly matched the
    /// contemporaneous Unix clock within 0...1 seconds on the current strap.
    struct ClockObservation: Equatable, Sendable {
        let responseSequence: UInt8
        let requestSequenceEcho: UInt8
        let observedPrefix: UInt8
        let deviceUnix: UInt32
        let opaqueTail: [UInt8]
    }

    static func parseClockObservation(
        _ bytes: [UInt8],
        command: UInt8 = 0x0b
    ) throws -> ClockObservation {
        let envelope = try parseCommandResponse(bytes)
        guard envelope.commandEcho == command else {
            throw ParseError.unexpectedCommand(
                actual: envelope.commandEcho,
                expected: command
            )
        }
        guard envelope.data.count >= 5 else {
            throw ParseError.tooShort(
                actual: envelope.data.count,
                required: 5
            )
        }
        return ClockObservation(
            responseSequence: envelope.responseSequence,
            requestSequenceEcho: envelope.requestSequenceEcho,
            observedPrefix: envelope.data[0],
            deviceUnix: u32LE(envelope.data, at: 1),
            opaqueTail: Array(envelope.data.dropFirst(5))
        )
    }

    /// One literal eight-byte record from the observed `0x22 [00]` response
    /// body. The first word looks like Unix time in existing captures; the
    /// second word remains opaque. Neither word is a validated `0x21` payload.
    struct DataRangeObservedRecord: Equatable, Sendable {
        let bodyOffset: Int
        let unixCandidate: UInt32
        let opaqueWord: UInt32
        let rawBytes: [UInt8]
    }

    /// Parsed shape of the one physically repeatable `GET_DATA_RANGE` response.
    /// The observed command data starts with `01 01`; its remaining 66 bytes
    /// contain eight-byte records at body offsets 40, 48, and 56.
    struct DataRangeObservation: Equatable, Sendable {
        let responseSequence: UInt8
        let requestSequenceEcho: UInt8
        let observedPrefix: [UInt8]
        let body: [UInt8]
        let records: [DataRangeObservedRecord]
    }

    static func parseDataRangeObservation(
        _ bytes: [UInt8],
        command: UInt8 = 0x22
    ) throws -> DataRangeObservation {
        let envelope = try parseCommandResponse(bytes)
        guard envelope.commandEcho == command else {
            throw ParseError.unexpectedCommand(
                actual: envelope.commandEcho,
                expected: command
            )
        }
        guard envelope.data.count >= 2 else {
            throw ParseError.tooShort(
                actual: envelope.data.count,
                required: 2
            )
        }
        let body = Array(envelope.data.dropFirst(2))
        let offsets = [40, 48, 56]
        guard let requiredEnd = offsets.last.map({ $0 + 8 }),
              body.count >= requiredEnd else {
            throw ParseError.missingObservedDataRangeRecords(
                actualBodyBytes: body.count
            )
        }
        let records = offsets.map { offset in
            let raw = Array(body[offset..<(offset + 8)])
            return DataRangeObservedRecord(
                bodyOffset: offset,
                unixCandidate: u32LE(raw, at: 0),
                opaqueWord: u32LE(raw, at: 4),
                rawBytes: raw
            )
        }
        return DataRangeObservation(
            responseSequence: envelope.responseSequence,
            requestSequenceEcho: envelope.requestSequenceEcho,
            observedPrefix: Array(envelope.data.prefix(2)),
            body: body,
            records: records
        )
    }

    /// The first four bytes after a `0x31` marker repeatedly tracked the strap
    /// clock. This observation is deliberately separate from the production
    /// metadata parser, where these bytes are not required to ACK safely.
    struct HistoryStartClockObservation: Equatable, Sendable {
        let metadataSequence: UInt8
        let deviceUnix: UInt32
        let opaqueTail: [UInt8]
    }

    static func parseHistoryStartClockObservation(
        _ bytes: [UInt8]
    ) throws -> HistoryStartClockObservation {
        guard bytes.count >= 7 else {
            throw ParseError.tooShort(actual: bytes.count, required: 7)
        }
        guard bytes[0] == metadataPacketType else {
            throw ParseError.unexpectedPacketType(bytes[0])
        }
        guard bytes[2] == 0x01 else {
            throw ParseError.unexpectedMetadataMarker(bytes[2])
        }
        return HistoryStartClockObservation(
            metadataSequence: bytes[1],
            deviceUnix: u32LE(bytes, at: 3),
            opaqueTail: Array(bytes.dropFirst(7))
        )
    }

    /// Evidence sufficient to correlate a clock response and a history-start
    /// marker with the exact two transmitted request sequences. This is still
    /// research evidence: it does not prove that the `0x16` payload selected a
    /// requested time range.
    struct AttemptBoundClockObservation: Equatable, Sendable {
        let clockRequestSequence: UInt8
        let historyRequestSequence: UInt8
        let clockResponseSequence: UInt8
        let historyResponseSequence: UInt8
        let historyMetadataSequence: UInt8
        let clockDeviceUnix: UInt32
        let historyStartDeviceUnix: UInt32

        var deviceClockAdvanceSeconds: UInt32 {
            historyStartDeviceUnix - clockDeviceUnix
        }
    }

    static func bindAttemptClock(
        clockRequestSequence: UInt8,
        historyRequestSequence: UInt8,
        clockResponseBytes: [UInt8],
        historyResponseBytes: [UInt8],
        historyStartBytes: [UInt8],
        maximumClockAdvanceSeconds: UInt32 = 30
    ) -> AttemptBoundClockObservation? {
        guard let clock = try? parseClockObservation(clockResponseBytes),
              let historyResponse = try? parseCommandResponse(historyResponseBytes),
              let historyStart = try? parseHistoryStartClockObservation(historyStartBytes),
              clock.requestSequenceEcho == clockRequestSequence,
              clock.observedPrefix == 0x01,
              historyResponse.commandEcho == 0x16,
              historyResponse.requestSequenceEcho == historyRequestSequence,
              clock.deviceUnix >= 1_500_000_000,
              clock.deviceUnix <= 2_200_000_000,
              historyStart.deviceUnix >= clock.deviceUnix,
              historyStart.deviceUnix - clock.deviceUnix <= maximumClockAdvanceSeconds else {
            return nil
        }
        return AttemptBoundClockObservation(
            clockRequestSequence: clockRequestSequence,
            historyRequestSequence: historyRequestSequence,
            clockResponseSequence: clock.responseSequence,
            historyResponseSequence: historyResponse.responseSequence,
            historyMetadataSequence: historyStart.metadataSequence,
            clockDeviceUnix: clock.deviceUnix,
            historyStartDeviceUnix: historyStart.deviceUnix
        )
    }

    private static func u32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
