import XCTest
@testable import Atria

final class AtriaBLEProductionHistoryHandshakeTests: XCTestCase {
    func testPhysicalRangeResponseSurvivesNotificationReassemblyAndFrameParsing() throws {
        let payload = try bytes(
            from: "24a722000101c0080000c508000091080000c0080000120000000000020002531300d60100002f634a6a482d00002f634a6a482d00005f634a6aa03500001e2b5d6a707d00000000"
        )
        let framedResponse = encodeFrame(payload)
        let reassembler = AtriaWhoop4FrameReassembler()

        // Exercise a split inside the response rather than handing the decoded
        // command payload directly to the range parser. This is the same lower
        // transport path used by the manager for RX/stream notifications.
        let split = 37
        XCTAssertTrue(
            reassembler.feed(
                framedResponse.prefix(split),
                source: "RX/resp"
            ).isEmpty
        )
        let frames = reassembler.feed(
            framedResponse.suffix(from: split),
            source: "RX/resp"
        )
        let frame = try XCTUnwrap(frames.only)
        let parsedFrame = try XCTUnwrap(
            AtriaFrame.parse(frame, source: "RX/resp")
        )

        XCTAssertEqual(parsedFrame.opcode, 0x24)
        XCTAssertTrue(parsedFrame.wellFormed)
        XCTAssertEqual([UInt8](parsedFrame.payload), payload)
        let range = try XCTUnwrap(
            AtriaWhoop4HistoryCursorRange.parseCommandResponse(
                [UInt8](parsedFrame.payload)
            )
        )
        XCTAssertEqual(range.requestSequenceEcho, 0x00)
        XCTAssertEqual(range.pendingRecords, 131_025)
        XCTAssertEqual(range.deviceUnix, 1_784_490_782)
    }

    func testSuccessfulPhysicalRangeResponseParsesCursorAndClockAuthority() throws {
        // Captured from the successful 2026-07-20 WHOOP 4.0 read-only run.
        // This is the complete 0x22 response, not a synthesized cursor packet.
        let payload = try bytes(
            from: "24a722000101c0080000c508000091080000c0080000120000000000020002531300d60100002f634a6a482d00002f634a6a482d00005f634a6aa03500001e2b5d6a707d00000000"
        )

        XCTAssertEqual(Array(payload[62...65]), [0x1e, 0x2b, 0x5d, 0x6a])

        let range = try XCTUnwrap(
            AtriaWhoop4HistoryCursorRange.parseCommandResponse(payload)
        )
        XCTAssertEqual(range.responseSequence, 0xa7)
        XCTAssertEqual(range.requestSequenceEcho, 0x00)
        XCTAssertEqual(range.writeCursor, 2_193)
        XCTAssertEqual(range.readCursor, 2_240)
        XCTAssertEqual(range.capacity, 131_072)
        XCTAssertEqual(range.pendingRecords, 131_025)
        XCTAssertEqual(range.deviceUnix, 1_784_490_782)

        let authority = try XCTUnwrap(
            AtriaWhoop4ProductionHistoryBootstrapPolicy.validatedClockAuthority(
                range: range,
                responseWallUnix: 1_784_490_797
            )
        )
        XCTAssertEqual(authority.deviceUnix, 1_784_490_782)
        XCTAssertEqual(authority.wallUnix, 1_784_490_797)
        XCTAssertEqual(authority.driftSeconds, 15)
    }

    func testClockAuthorityFailsClosedWithoutRangeClockOrWithImplausibleWallTime() throws {
        let fullPayload = try bytes(
            from: "24a722000101c0080000c508000091080000c0080000120000000000020002531300d60100002f634a6a482d00002f634a6a482d00005f634a6aa03500001e2b5d6a707d00000000"
        )
        let shortRange = try XCTUnwrap(
            AtriaWhoop4HistoryCursorRange.parseCommandResponse(
                Array(fullPayload.prefix(62))
            )
        )
        XCTAssertNil(shortRange.deviceUnix)
        XCTAssertNil(
            AtriaWhoop4ProductionHistoryBootstrapPolicy.validatedClockAuthority(
                range: shortRange,
                responseWallUnix: 1_784_490_797
            )
        )

        let physicalRange = try XCTUnwrap(
            AtriaWhoop4HistoryCursorRange.parseCommandResponse(fullPayload)
        )
        XCTAssertNil(
            AtriaWhoop4ProductionHistoryBootstrapPolicy.validatedClockAuthority(
                range: physicalRange,
                responseWallUnix: 1_784_490_782 + 86_401
            )
        )
        XCTAssertNil(
            AtriaWhoop4ProductionHistoryBootstrapPolicy.validatedClockAuthority(
                range: physicalRange,
                responseWallUnix: .nan
            )
        )
    }

    func testPostRangeResponseSettleRequiresOrderedFullTwoSeconds() {
        let policy = AtriaWhoop4ProductionHistoryBootstrapPolicy.self
        XCTAssertFalse(policy.hasCompletedPostResponseSettle(
            responseUptime: 100,
            nowUptime: 101.999
        ))
        XCTAssertTrue(policy.hasCompletedPostResponseSettle(
            responseUptime: 100,
            nowUptime: 102
        ))
        XCTAssertFalse(policy.hasCompletedPostResponseSettle(
            responseUptime: 100,
            nowUptime: 99
        ))
        XCTAssertFalse(policy.hasCompletedPostResponseSettle(
            responseUptime: .nan,
            nowUptime: 102
        ))
    }

    private func bytes(from hex: String) throws -> [UInt8] {
        guard hex.count.isMultiple(of: 2) else {
            throw FixtureError.oddLength
        }
        return try stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            guard let byte = UInt8(hex[start..<end], radix: 16) else {
                throw FixtureError.invalidHex
            }
            return byte
        }
    }

    private enum FixtureError: Error {
        case oddLength
        case invalidHex
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
