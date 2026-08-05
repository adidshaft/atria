import CryptoKit
import Foundation

/// Stable consumer-side identity for one recovered motion frame.
///
/// Historical archives can contain exact row replays from older persistence
/// paths. Those replays must not inflate motion density, while two frames that
/// share clock/counter metadata but carry different payloads must remain
/// distinct. Keep this policy independent from archive scanning so every
/// recovered-motion consumer uses the same full raw-record identity.
struct AtriaRecoveredMotionReplayIdentity: Hashable, Sendable {
    /// 33-byte inline payload identity (2026-08-05 bounding design, Edit 1):
    /// SHA-256 over exactly the normalized bytes this type previously
    /// retained, plus a kind tag keeping the wellFormedBytes/malformed
    /// domains separated (identical digest input across domains must not
    /// merge). Retaining the payload itself pinned ~750K heap allocations
    /// between recomputes at the motion-identity budget cap; a false merge
    /// now requires a same-kind SHA-256 collision. This set is internal
    /// dedup state only — nothing reads payload bytes back out of it.
    struct PayloadDigest: Hashable, Sendable {
        enum Kind: UInt8, Hashable, Sendable {
            case wellFormedBytes
            case malformed
        }

        let word0: UInt64
        let word1: UInt64
        let word2: UInt64
        let word3: UInt64
        let kind: Kind

        init(kind: Kind, digesting data: Data) {
            self.kind = kind
            let digest = SHA256.hash(data: data)
            let words: (UInt64, UInt64, UInt64, UInt64) = digest.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                 raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            }
            word0 = words.0
            word1 = words.1
            word2 = words.2
            word3 = words.3
        }
    }

    let source: String
    let layoutVersion: String
    let flashCounter: UInt32
    let unixSeconds: UInt32
    let subsecond: UInt16
    /// Projection time is cache-retention metadata, not physical replay
    /// identity. Equality deliberately remains anchored to the raw frame.
    let projectedTimestamp: TimeInterval
    /// Exact payload identity as an inline digest. Malformed fixture/forensic
    /// values remain exact and distinct from decodable byte payloads.
    let payload: PayloadDigest

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

    private static func payload(_ rawPayloadHex: String) -> PayloadDigest {
        // Fast path (2026-08-04 scan-garbage fix): the archive writer only
        // ever emits already-normalized hex (lowercase, no whitespace), and
        // this runs once per scanned line — decode straight from UTF-8
        // without the Character filter + lowercased copies. Anything else
        // (uppercase, whitespace, unicode, malformed) falls through to the
        // original normalization so identity values stay byte-identical.
        // Digest inputs are the exact bytes each branch previously retained:
        // decoded bytes for wellFormedBytes, the normalized string's UTF-8
        // for malformed.
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
            return PayloadDigest(kind: .wellFormedBytes, digesting: bytes)
        }
        let normalized = rawPayloadHex
            .filter { !$0.isWhitespace }
            .lowercased()
        guard normalized.count.isMultiple(of: 2) else {
            return PayloadDigest(kind: .malformed, digesting: Data(normalized.utf8))
        }
        var bytes = Data()
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                return PayloadDigest(kind: .malformed, digesting: Data(normalized.utf8))
            }
            bytes.append(byte)
            index = next
        }
        return PayloadDigest(kind: .wellFormedBytes, digesting: bytes)
    }
}
