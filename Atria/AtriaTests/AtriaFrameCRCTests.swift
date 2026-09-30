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

/// 2026-09-27 main-thread hang: the open-span gyro score is memoised; it must
/// always equal a fresh recompute of the same state.
final class AtriaGyroOpenSpanMemoTests: XCTestCase {
    func testMemoisedBoundaryTotalMatchesFreshRecompute() {
        var state = AtriaGyroCadenceResearchShadow.State()
        var reference = AtriaGyroCadenceResearchShadow.State()
        var ts: UInt32 = 1_790_000_000
        for second in 0..<120 {
            let walking = (30..<90).contains(second)
            let magnitudes = (0..<100).map { i -> Double in
                walking ? 60 + 55 * sin(Double(second * 100 + i) * 2 * .pi / 55.0) : 1.5
            }
            _ = state.ingest(deviceTimestamp: ts, rotationMagnitudes: magnitudes)
            _ = reference.ingest(deviceTimestamp: ts, rotationMagnitudes: magnitudes)
            ts += 1
            let memoFirst = state.boundaryTotalSteps()
            let memoSecond = state.boundaryTotalSteps()   // served from the memo
            var fresh = reference
            XCTAssertEqual(memoFirst, memoSecond)
            XCTAssertEqual(memoFirst, fresh.boundaryTotalSteps(), accuracy: 1e-9)
        }
        XCTAssertGreaterThan(state.boundaryTotalSteps(), 0, "the synthetic walk registers steps")
    }

    /// 2026-09-30 background cpu_resource_fatal: the open span is scored
    /// incrementally. Per-second boundary totals (and the size-bound cut at
    /// 10 minutes) must equal the batch pedometer over the same samples.
    func testIncrementalScoringMatchesBatchPedometerAcrossSizeBoundCut() {
        typealias Shadow = AtriaGyroCadenceResearchShadow
        var state = Shadow.State()
        var ts: UInt32 = 1_790_000_000
        var all: [Double] = []
        var closedBatch = 0.0
        var observed = 0.0
        var spanStart = 0
        for second in 0..<660 {
            let walking = (second % 200) >= 40
            let magnitudes = (0..<100).map { i -> Double in
                walking ? 60 + 55 * sin(Double(second * 100 + i) * 2 * .pi / 55.0) : 1.5
            }
            let before = state.snapshot().closedSpans
            _ = state.ingest(deviceTimestamp: ts, rotationMagnitudes: magnitudes)
            ts += 1
            all.append(contentsOf: magnitudes)
            if state.snapshot().closedSpans > before {
                let prefix = all.count - spanStart - Shadow.carrySamples
                closedBatch += AtriaGyroCadenceResearchPedometer.steps(
                    contiguousRotationMagnitudes: Array(all[spanStart..<(spanStart + prefix)])
                )
                spanStart += prefix
            }
            if second % 30 == 0 || (596...604).contains(second) {
                let open = AtriaGyroCadenceResearchPedometer.steps(
                    contiguousRotationMagnitudes: Array(all[spanStart...])
                )
                // Totals are monotonic: a bout split by the cut may score a
                // little lower than it did whole, and the higher total stands.
                observed = max(observed, closedBatch + open)
                XCTAssertEqual(state.boundaryTotalSteps(), observed, accuracy: 1e-9,
                               "second \(second)")
            }
        }
        XCTAssertEqual(state.snapshot().closedSpans, 1, "the 10-minute size bound cut once")
        XCTAssertGreaterThan(closedBatch, 0)
    }
}
