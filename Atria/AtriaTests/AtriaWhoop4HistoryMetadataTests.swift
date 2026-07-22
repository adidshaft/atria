import XCTest
@testable import Atria

final class AtriaWhoop4HistoryMetadataTests: XCTestCase {
    func testParsesHistoryStart() throws {
        XCTAssertEqual(
            try AtriaWhoop4HistoryMetadata.parse([0x31, 0x27, 0x01]),
            .historyStart(sequence: 0x27)
        )
    }

    func testParsesHistoryComplete() throws {
        XCTAssertEqual(
            try AtriaWhoop4HistoryMetadata.parse([0x31, 0xA4, 0x03]),
            .historyComplete(sequence: 0xA4)
        )
    }

    func testParsesOpaqueHistoryEndStatusAndExactToken() throws {
        let payload = metadataHex(
            "3100020000000000002a0000001122334455667788"
        )

        let marker = try AtriaWhoop4HistoryMetadata.parse(payload)
        guard case let .historyEnd(sequence, opaqueStatusWord, token) = marker else {
            return XCTFail("Expected HISTORY_END")
        }

        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(opaqueStatusWord, 42)
        XCTAssertEqual(token.bytes, metadataHex("1122334455667788"))
        XCTAssertEqual(
            token.acknowledgementPayload,
            metadataHex("011122334455667788")
        )
    }

    func testHistoryEndTokenComesFromFixedOffsetsNotPacketTail() throws {
        let fixedToken = metadataHex("deadbeef11223344")
        let extensionBytes = metadataHex("aabbccddeeff0011")
        let payload = metadataHex("31070200000000000005000000")
            + fixedToken
            + extensionBytes

        let marker = try AtriaWhoop4HistoryMetadata.parse(payload)
        guard case let .historyEnd(_, opaqueStatusWord, token) = marker else {
            return XCTFail("Expected HISTORY_END")
        }

        XCTAssertEqual(opaqueStatusWord, 5)
        XCTAssertEqual(token.bytes, fixedToken)
        XCTAssertEqual(token.acknowledgementPayload, [0x01] + fixedToken)
        XCTAssertNotEqual(token.bytes, extensionBytes)
    }

    func testRejectsEveryTruncatedHistoryEndToken() {
        let complete = metadataHex(
            "3100020000000000002a0000001122334455667788"
        )

        for length in 13..<21 {
            XCTAssertThrowsError(
                try AtriaWhoop4HistoryMetadata.parse(Array(complete.prefix(length))),
                "Length \(length) must not produce an ACK token"
            ) { error in
                XCTAssertEqual(
                    error as? AtriaWhoop4HistoryMetadata.ParseError,
                    .tooShort(actual: length, required: 21)
                )
            }
        }
    }

    func testTokenTypeRejectsAnythingOtherThanEightBytes() {
        for length in [0, 4, 7, 9, 12] {
            XCTAssertThrowsError(
                try AtriaWhoop4HistoryEndToken(bytes: Array(repeating: 0xAA, count: length))
            ) { error in
                XCTAssertEqual(
                    error as? AtriaWhoop4HistoryEndToken.ValidationError,
                    .invalidLength(actual: length, required: 8)
                )
            }
        }
    }

    func testRejectsMalformedOrUnsupportedMetadata() {
        XCTAssertThrowsError(try AtriaWhoop4HistoryMetadata.parse([])) { error in
            XCTAssertEqual(
                error as? AtriaWhoop4HistoryMetadata.ParseError,
                .tooShort(actual: 0, required: 3)
            )
        }
        XCTAssertThrowsError(
            try AtriaWhoop4HistoryMetadata.parse([0x30, 0x00, 0x01])
        ) { error in
            XCTAssertEqual(
                error as? AtriaWhoop4HistoryMetadata.ParseError,
                .unexpectedPacketType(0x30)
            )
        }
        XCTAssertThrowsError(
            try AtriaWhoop4HistoryMetadata.parse([0x31, 0x00, 0xFF])
        ) { error in
            XCTAssertEqual(
                error as? AtriaWhoop4HistoryMetadata.ParseError,
                .unsupportedMarker(0xFF)
            )
        }
    }
}

private func metadataHex(_ string: String) -> [UInt8] {
    stride(from: 0, to: string.count, by: 2).compactMap { offset in
        let start = string.index(string.startIndex, offsetBy: offset)
        let end = string.index(start, offsetBy: 2)
        return UInt8(string[start..<end], radix: 16)
    }
}
