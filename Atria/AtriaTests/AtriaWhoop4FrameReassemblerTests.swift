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

    func testPreservesPhysicalACKResponseImmediatelyFollowedByHistoryStart() {
        let ack = encodeFrame([0x24, 0xd0, 0x17, 0x00, 0x01, 0x00, 0x00, 0x00])
        let historyStart = encodeFrame([0x31, 0xd1])
        let reassembler = AtriaWhoop4FrameReassembler()
        var coalesced = Data(ack)
        coalesced.append(historyStart)

        XCTAssertEqual(
            reassembler.feed(coalesced, source: "stream5"),
            [ack, historyStart]
        )
        XCTAssertEqual(reassembler.bufferedByteCount(source: "stream5"), 0)
    }

    func testHistoricalFragmentCannotCrossServeArmBoundary() throws {
        let frame = encodeFrame(
            [0x2f, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        )
        let split = frame.count / 2
        let fence = AtriaBLEHistoryTransportPhaseFence()
        let preServe = fence.activate(generation: 81)
        let reassembler = AtriaWhoop4FrameReassembler()

        XCTAssertTrue(reassembler.feed(
            frame.prefix(split),
            source: "stream5",
            scope: .init(
                historyGeneration: preServe.generation,
                historyServeToken: preServe.serveToken
            )
        ).isEmpty)
        let serving = try XCTUnwrap(fence.armServe(ifMatching: 81))
        XCTAssertTrue(reassembler.feed(
            frame.suffix(from: split),
            source: "stream5",
            scope: .init(
                historyGeneration: serving.generation,
                historyServeToken: serving.serveToken
            )
        ).isEmpty)

        reassembler.reset(source: "stream5")
        XCTAssertEqual(reassembler.feed(
            frame,
            source: "stream5",
            scope: .init(
                historyGeneration: serving.generation,
                historyServeToken: serving.serveToken
            )
        ), [frame])
    }

    func testHistoricalFragmentCannotCrossPageCommandBoundary() throws {
        let frame = encodeFrame(
            [0x31, 0x74, 0x0e, 0x09, 0x08, 0x07, 0x06]
        )
        let split = frame.count / 2
        let fence = AtriaBLEHistoryTransportPhaseFence()
        _ = fence.activate(generation: 82)
        let firstPage = try XCTUnwrap(fence.armServe(ifMatching: 82))
        let reassembler = AtriaWhoop4FrameReassembler()

        XCTAssertTrue(reassembler.feed(
            frame.prefix(split),
            source: "RX/resp",
            scope: .init(
                historyGeneration: firstPage.generation,
                historyServeToken: firstPage.serveToken
            )
        ).isEmpty)
        let nextPage = try XCTUnwrap(fence.armServe(ifMatching: 82))
        XCTAssertNotEqual(firstPage.serveToken, nextPage.serveToken)
        XCTAssertTrue(reassembler.feed(
            frame.suffix(from: split),
            source: "RX/resp",
            scope: .init(
                historyGeneration: nextPage.generation,
                historyServeToken: nextPage.serveToken
            )
        ).isEmpty)
    }
}
