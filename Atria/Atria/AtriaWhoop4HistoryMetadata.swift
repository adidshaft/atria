/// Side-effect-free parsing for WHOOP 4.0 historical-stream metadata (`0x31`).
///
/// Transport framing and CRC validation happen before this parser. The input is
/// the complete inner payload beginning with packet type `0x31`.
enum AtriaWhoop4HistoryMetadata {
    static let packetType: UInt8 = 0x31

    enum Marker: Equatable, Sendable {
        case historyStart(sequence: UInt8)
        case historyEnd(
            sequence: UInt8,
            opaqueStatusWord: UInt32,
            token: AtriaWhoop4HistoryEndToken
        )
        case historyComplete(sequence: UInt8)
    }

    enum ParseError: Error, Equatable, Sendable {
        case tooShort(actual: Int, required: Int)
        case unexpectedPacketType(UInt8)
        case unsupportedMarker(UInt8)
    }

    /// Parse a metadata inner payload without guessing alternate cursor fields.
    ///
    /// A `HISTORY_END` token is always the fixed eight bytes at inner offsets
    /// `13..<21`. Those bytes are opaque: they must never be reinterpreted as a
    /// timestamp, index, or trim cursor before acknowledgement.
    static func parse(_ bytes: [UInt8]) throws -> Marker {
        guard bytes.count >= 3 else {
            throw ParseError.tooShort(actual: bytes.count, required: 3)
        }
        guard bytes[0] == packetType else {
            throw ParseError.unexpectedPacketType(bytes[0])
        }

        let sequence = bytes[1]
        switch bytes[2] {
        case 0x01:
            return .historyStart(sequence: sequence)
        case 0x02:
            // WHOOP 4 inner[9..<13] is an opaque status/cursor word. Physical
            // captures prove it is not the number of 0x2f records in this
            // batch, so it must never be used to decide whether an ACK is safe.
            // opaque continuation token: inner[13..<21]
            guard bytes.count >= 21 else {
                throw ParseError.tooShort(actual: bytes.count, required: 21)
            }
            let opaqueStatusWord = u32LE(bytes, at: 9)
            let token = try AtriaWhoop4HistoryEndToken(bytes: Array(bytes[13..<21]))
            return .historyEnd(
                sequence: sequence,
                opaqueStatusWord: opaqueStatusWord,
                token: token
            )
        case 0x03:
            return .historyComplete(sequence: sequence)
        default:
            throw ParseError.unsupportedMarker(bytes[2])
        }
    }

    private static func u32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// The opaque eight-byte continuation token carried by `HISTORY_END`.
///
/// The validated type makes it impossible for the ACK builder to accidentally
/// accept a four-byte timestamp/index/trim cursor or a truncated token.
struct AtriaWhoop4HistoryEndToken: Equatable, Sendable {
    static let byteCount = 8

    enum ValidationError: Error, Equatable, Sendable {
        case invalidLength(actual: Int, required: Int)
    }

    let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw ValidationError.invalidLength(
                actual: bytes.count,
                required: Self.byteCount
            )
        }
        self.bytes = bytes
    }

    /// Payload for historical-data-result command `0x17`.
    ///
    /// This is deliberately only `[success = 0x01] + token`; the command
    /// transport owns packet type, sequence number, framing, and CRC bytes.
    var acknowledgementPayload: [UInt8] {
        [0x01] + bytes
    }
}
