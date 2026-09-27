import XCTest
@testable import Atria

/// The table-driven CRC-32 (2026-09-24) must be bit-identical to the former
/// bit-by-bit implementation that every WHOOP frame check relied on.
final class AtriaFrameCRCTests: XCTestCase {
    /// Verbatim copy of the previous implementation, kept as the oracle.
    private func legacyCRC32(_ bytes: [UInt8]) -> UInt32 {
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

    func testStandardCheckValue() {
        XCTAssertEqual(crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(crc32([UInt8]()), 0)
    }

    func testMatchesLegacyOnRandomFrameSizedBuffers() {
        var generator = SystemRandomNumberGenerator()
        for length in [1, 5, 104, 152, 1_924, 2_048, 4_000] {
            for _ in 0..<20 {
                let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
                let expected = legacyCRC32(bytes)
                XCTAssertEqual(crc32(bytes), expected)
                XCTAssertEqual(crc32(Data(bytes)), expected)
                XCTAssertEqual(crc32(bytes[...]), expected)
                XCTAssertEqual(crc32(bytes.lazy.map { $0 }), expected, "generic overload")
            }
        }
    }

    func testTwoKilobyteFrameIsCheap() {
        let frame = [UInt8](repeating: 0xAB, count: 2_048)
        measure { for _ in 0..<500 { _ = crc32(frame) } }
    }
}
