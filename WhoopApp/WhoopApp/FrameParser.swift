import Foundation

/// One decoded frame from the WHOOP proprietary stream.
///
/// Wire format (verified against captures):
///   aa | len(2, little-endian) | crc8(len) | payload... | checksum(4)
///
/// The `len` field is `payload.count + 4`, so `total = len + 4`. The byte right
/// after `len` is the CRC8 header byte; the payload's first byte is the packet
/// type/opcode.
struct WhoopFrame: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let source: String        // which characteristic it came from
    let opcode: UInt8         // payload type/opcode
    let declaredLen: Int      // value of the len field (= total - 4)
    let payload: Data         // bytes from packet type through end of body (excludes checksum)
    let checksum: Data        // the 4 trailing CRC32 bytes
    let wellFormed: Bool      // did preamble + length line up with the data we got?
    let raw: Data             // the full frame as received

    var hex: String { raw.map { String(format: "%02x", $0) }.joined() }
    var checksumHex: String { checksum.map { String(format: "%02x", $0) }.joined() }

    static func parse(_ data: Data, source: String) -> WhoopFrame? {
        let b = [UInt8](data)
        // Minimum sensible frame: aa + len(2) + crc8(1) + type(1) + checksum(4)
        guard b.count >= 8, b[0] == 0xAA else {
            // Unknown shape — still surface it raw rather than dropping it.
            return WhoopFrame(source: source, opcode: b.first ?? 0, declaredLen: b.count,
                              payload: data, checksum: Data(), wellFormed: false, raw: data)
        }
        let len = Int(b[1]) | (Int(b[2]) << 8)      // counts everything but the 4B checksum
        let wellFormed = (len + 4 == b.count) && len >= 4
        let payloadStart = 4
        let payloadEnd = min(max(len, payloadStart), b.count)
        let payload = payloadStart < payloadEnd ? Data(b[payloadStart..<payloadEnd]) : Data()
        let checksum = payloadEnd + 4 <= b.count ? Data(b[payloadEnd..<payloadEnd+4]) : Data(b[payloadEnd...])
        return WhoopFrame(source: source, opcode: payload.first ?? 0, declaredLen: len,
                          payload: payload, checksum: checksum, wellFormed: wellFormed, raw: data)
    }
}

/// CRC-32/ISO-HDLC (zlib), forward-reflected form: poly 0x04C11DB7, init 0xFFFFFFFF,
/// reflect-in/reflect-out, final XOR 0xFFFFFFFF. Verified to match Python's
/// zlib.crc32 AND the real WHOOP device frame trailer (the previous reflected
/// `>>` variant did NOT — it produced an invalid checksum the strap rejected,
/// which is why realtime never started on iOS).
func crc32(_ bytes: [UInt8]) -> UInt32 {
    func reflect8(_ x: UInt8) -> UInt32 {
        var v = x, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return UInt32(r)
    }
    func reflect32(_ x: UInt32) -> UInt32 {
        var v = x, r: UInt32 = 0
        for _ in 0..<32 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }
    var crc: UInt32 = 0xFFFFFFFF
    for b in bytes {
        crc ^= reflect8(b) << 24
        for _ in 0..<8 {
            crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
        }
    }
    return reflect32(crc) ^ 0xFFFFFFFF
}

/// CRC-8 (poly 0x07, init 0x00) — used over the 2 length bytes.
func crc8(_ bytes: [UInt8]) -> UInt8 {
    var c: UInt8 = 0
    for b in bytes {
        c ^= b
        for _ in 0..<8 {
            c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : (c << 1)
        }
    }
    return c
}

/// Wrap a payload in a valid WHOOP frame the strap will accept:
///   0xAA | len(LE) | CRC8(len) | payload | CRC32(payload, LE)   (len = payload+4)
func encodeFrame(_ payload: [UInt8]) -> Data {
    let len = UInt16(payload.count + 4)
    let lenBytes = [UInt8(len & 0xFF), UInt8(len >> 8)]
    var out: [UInt8] = [0xAA] + lenBytes + [crc8(lenBytes)] + payload
    let c = crc32(payload)
    out += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 24) & 0xFF)]
    return Data(out)
}
