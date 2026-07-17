import XCTest
@testable import Atria

final class AtriaWhoop4FrameReassemblerTests: XCTestCase {
    func testReassemblesLargeFrameWithoutResettingOnEmbeddedStartBytes() {
        var payload = [UInt8](repeating: 0x11, count: 1_920)
        payload[0] = 0x2B
        payload[1] = 0x0A
        payload[611] = 0xAA
        payload[1_407] = 0xAA
        let frame = encodeFrame(payload)
        let reassembler = AtriaWhoop4FrameReassembler()

        var output: [Data] = []
        var offset = 0
        while offset < frame.count {
            let end = min(frame.count, offset + 244)
            output += reassembler.feed(frame.subdata(in: offset..<end), source: "stream5")
            offset = end
        }

        XCTAssertEqual(output, [frame])
        XCTAssertEqual(reassembler.bufferedByteCount(source: "stream5"), 0)
    }

    func testKeepsInterleavedCharacteristicBuffersIndependent() {
        let first = encodeFrame([0x28, 1, 2, 3, 4, 5, 6, 7, 70, 0])
        let second = encodeFrame([0x24, 4, 3, 2, 1])
        let reassembler = AtriaWhoop4FrameReassembler()
        let split = first.count / 2

        XCTAssertTrue(reassembler.feed(first.prefix(split), source: "stream5").isEmpty)
        XCTAssertEqual(reassembler.feed(second, source: "stream3"), [second])
        XCTAssertEqual(reassembler.feed(first.suffix(from: split), source: "stream5"), [first])
    }

    func testRejectsCorruptFrameThenResynchronizesToNextValidFrame() {
        var corrupt = encodeFrame([0x2B, 0x0A] + [UInt8](repeating: 0x44, count: 80))
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xFF
        let valid = encodeFrame([0x28, 0, 0, 0, 0, 0, 0, 0, 62, 0])
        let reassembler = AtriaWhoop4FrameReassembler()

        let output = reassembler.feed(corrupt + valid, source: "stream5")

        XCTAssertEqual(output, [valid])
    }

    func testSplitsConcatenatedFramesAndSkipsNullPadding() {
        let first = encodeFrame([0x24, 1, 2, 3])
        let second = encodeFrame([0x31, 4, 5, 6, 7])
        let reassembler = AtriaWhoop4FrameReassembler()
        var bytes = Data(first)
        bytes.append(contentsOf: [0, 0, 0])
        bytes.append(second)

        XCTAssertEqual(reassembler.feed(bytes, source: "stream3"), [first, second])
    }
}
