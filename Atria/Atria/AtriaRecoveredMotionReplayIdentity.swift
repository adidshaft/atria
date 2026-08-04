import Foundation

/// Stable consumer-side identity for one recovered motion frame.
///
/// Historical archives can contain exact row replays from older persistence
/// paths. Those replays must not inflate motion density, while two frames that
/// share clock/counter metadata but carry different payloads must remain
/// distinct. Keep this policy independent from archive scanning so every
/// recovered-motion consumer uses the same full raw-record identity.
struct AtriaRecoveredMotionReplayIdentity: Hashable, Sendable {
    enum Payload: Hashable, Sendable {
        case bytes(Data)
        case malformed(String)
    }

    let source: String
    let layoutVersion: String
    let flashCounter: UInt32
    let unixSeconds: UInt32
    let subsecond: UInt16
    /// Projection time is cache-retention metadata, not physical replay
    /// identity. Equality deliberately remains anchored to the raw frame.
    let projectedTimestamp: TimeInterval
    /// Exact payload identity stored as bytes when possible. Keeping a second
    /// full hex String doubled resident payload storage in the recovered-motion
    /// cache. Malformed fixture/forensic values remain exact and distinct.
    let payload: Payload

    init(
        source: String,
        layoutVersion: String,
        flashCounter: UInt32,
        unixSeconds: UInt32,
        subsecond: UInt16,
        rawPayloadHex: String,
        projectedTimestamp: TimeInterval? = nil
    ) {
        self.source = source
        self.layoutVersion = layoutVersion
        self.flashCounter = flashCounter
        self.unixSeconds = unixSeconds
        self.subsecond = subsecond
        self.projectedTimestamp = projectedTimestamp
            ?? TimeInterval(unixSeconds) + TimeInterval(subsecond) / 32_768
        payload = Self.payload(rawPayloadHex)
    }

    init(record: HistoricalArchive.Record) {
        self.init(source: record.source,
                  layoutVersion: record.layoutVersion,
                  flashCounter: record.flash13,
                  unixSeconds: record.unix7,
                  subsecond: record.subsec11,
                  rawPayloadHex: record.rawPayloadHex,
                  projectedTimestamp: TimeInterval(record.clockCorrectedUnix7 ?? record.unix7)
                    + TimeInterval(record.subsec11) / 32_768)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source
            && lhs.layoutVersion == rhs.layoutVersion
            && lhs.flashCounter == rhs.flashCounter
            && lhs.unixSeconds == rhs.unixSeconds
            && lhs.subsecond == rhs.subsecond
            && lhs.payload == rhs.payload
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(layoutVersion)
        hasher.combine(flashCounter)
        hasher.combine(unixSeconds)
        hasher.combine(subsecond)
        hasher.combine(payload)
    }

    private static func payload(_ rawPayloadHex: String) -> Payload {
        // Fast path (2026-08-04 scan-garbage fix): the archive writer only
        // ever emits already-normalized hex (lowercase, no whitespace), and
        // this runs once per scanned line — decode straight from UTF-8
        // without the Character filter + lowercased copies. Anything else
        // (uppercase, whitespace, unicode, malformed) falls through to the
        // original normalization so identity values stay byte-identical.
        var fastDecodable = true
        var count = 0
        for byte in rawPayloadHex.utf8 {
            switch byte {
            case 0x30...0x39, 0x61...0x66:
                count += 1
            default:
                fastDecodable = false
            }
            if !fastDecodable { break }
        }
        if fastDecodable, count.isMultiple(of: 2) {
            var bytes = Data(capacity: count / 2)
            var pending: UInt8 = 0
            var atHighNibble = true
            for byte in rawPayloadHex.utf8 {
                let digit = byte <= 0x39 ? byte - 0x30 : byte - 0x61 + 10
                if atHighNibble {
                    pending = digit << 4
                } else {
                    bytes.append(pending | digit)
                }
                atHighNibble.toggle()
            }
            return .bytes(bytes)
        }
        let normalized = rawPayloadHex
            .filter { !$0.isWhitespace }
            .lowercased()
        guard normalized.count.isMultiple(of: 2) else {
            return .malformed(normalized)
        }
        var bytes = Data()
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return .malformed(normalized)
            }
            bytes.append(byte)
            index = next
        }
        return .bytes(bytes)
    }
}
