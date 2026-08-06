import XCTest
@testable import Atria

final class AtriaWhoop4HistoricalRecordDecoderTests: XCTestCase {
    /// Captured by Atria from a real WHOOP 4.0 archive on 2026-07-06. This is
    /// copied verbatim from logs/live-device/dense-quiet-window-qualification-
    /// 20260718T095257Z/historical-archive.jsonl.
    private let capturedV24 = historicalHex(
        "2f1805444931019a76316a983a80545e015402cd02e802000000000000f760ff80" +
        "1b153cd763c9bd3313b9bd9a21833f00008245d763c9bd3313b9bd9a21833f5a" +
        "02cc021904ca0261019009010c020c3000000000000001306a000000000000"
    )

    /// Captured in the same real archive. v25 deliberately has no decoded HR/RR.
    private let capturedV25 = historicalHex(
        "2f1900eb530000d780316a88782400e6cc040039fecffcfcfce7fec000c0001801" +
        "2401d901e7016901a201340174003b002a00fdffa0ffc7ffbdff9fff6fff15ffd8" +
        "fe504b0f3d9009010000"
    )

    func testDecodesCapturedV24FixedFieldsAndPreservesProvenance() throws {
        let result = AtriaWhoop4HistoricalRecordDecoder.decode(
            capturedV24,
            origin: "atria-captured-historical-archive-2026-07"
        )
        let record = try XCTUnwrap(result.decodedRecord)

        XCTAssertEqual(record.layout, .v24)
        XCTAssertEqual(record.counter, 0x0131_4944)
        XCTAssertEqual(record.timestampSeconds, 1_781_626_522)
        XCTAssertEqual(record.subsecond, 15_000)
        XCTAssertEqual(record.physiology?.decodedHeartRateBPM, 84)
        XCTAssertEqual(record.physiology?.decodedRRIntervalsMilliseconds, [717, 744])
        XCTAssertEqual(record.physiology?.gate, .accepted)
        XCTAssertEqual(record.gravity.x, -0.09833496063947678, accuracy: 0.0000001)
        XCTAssertEqual(record.gravity.y, -0.09036865085363388, accuracy: 0.0000001)
        XCTAssertEqual(record.gravity.z, 1.0244629383087158, accuracy: 0.0000001)
        XCTAssertEqual(try XCTUnwrap(record.unknownMotionScalar32),
                       0.009100794792175293,
                       accuracy: 0.0000001)
        XCTAssertEqual(record.motionTickCounter, 27_184)
        XCTAssertEqual(record.provenance.origin, "atria-captured-historical-archive-2026-07")
        XCTAssertEqual(record.provenance.rawBytes, capturedV24)
        XCTAssertEqual(record.provenance.rawHex, capturedV24.hexString)
    }

    func testDecodesCapturedV25AsTimeAndGravityOnly() throws {
        let record = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(capturedV25).decodedRecord
        )

        XCTAssertEqual(record.layout, .v25)
        XCTAssertEqual(record.counter, 0x0000_53EB)
        XCTAssertEqual(record.timestampSeconds, 1_781_629_143)
        XCTAssertNil(record.subsecond)
        XCTAssertNil(record.physiology, "v25 must never manufacture HR or RR")
        XCTAssertNil(record.unknownMotionScalar32)
        XCTAssertNil(record.motionTickCounter)
        XCTAssertEqual(record.gravity.x, 15_631.0 / 16_384.0, accuracy: 0.0000001)
        XCTAssertEqual(record.gravity.y, 2_448.0 / 16_384.0, accuracy: 0.0000001)
        XCTAssertEqual(record.gravity.z, 1.0 / 16_384.0, accuracy: 0.0000001)
        XCTAssertEqual(record.provenance.rawBytes, capturedV25)
    }

    func testV12UsesTheV24FixedLayout() throws {
        var bytes = capturedV24
        bytes[1] = 12

        let record = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(bytes).decodedRecord
        )

        XCTAssertEqual(record.layout, .v12)
        XCTAssertEqual(record.physiology?.acceptedHeartRateBPM, 84)
        XCTAssertEqual(record.physiology?.acceptedRRIntervalsMilliseconds, [717, 744])
    }

    func testLegacyVersionsUseTheirKnownHeartRateOffsets() throws {
        for (version, offset, heartRate): (UInt8, Int, UInt8) in [
            (7, 27, 71),
            (9, 17, 72),
            (18, 14, 73),
        ] {
            var bytes = capturedV24
            bytes[1] = version
            bytes[offset] = heartRate

            let record = try XCTUnwrap(
                AtriaWhoop4HistoricalRecordDecoder.decode(bytes).decodedRecord
            )

            XCTAssertEqual(record.physiology?.decodedHeartRateBPM, Int(heartRate))
            XCTAssertEqual(record.physiology?.acceptedHeartRateBPM, Int(heartRate))
        }
    }

    func testLegacyPhysiologyFailsClosedForImplausibleHeartRate() throws {
        var bytes = capturedV24
        bytes[1] = 18
        bytes[14] = 5

        let physiology = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(bytes).decodedRecord?.physiology
        )

        XCTAssertEqual(physiology.decodedHeartRateBPM, 5, "decoded bytes remain inspectable")
        XCTAssertEqual(physiology.gate, .withheld(.heartRateOutOfRange(5)))
        XCTAssertNil(physiology.acceptedHeartRateBPM)
        XCTAssertNil(physiology.acceptedRRIntervalsMilliseconds)
    }

    func testLegacyPhysiologyFailsClosedForImplausibleGravity() throws {
        var bytes = capturedV24
        bytes[1] = 7
        bytes[27] = 65
        replaceFloat32LE(0, at: 36, in: &bytes)
        replaceFloat32LE(0, at: 40, in: &bytes)
        replaceFloat32LE(0, at: 44, in: &bytes)

        let physiology = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(bytes).decodedRecord?.physiology
        )

        XCTAssertEqual(physiology.gate, .withheld(.gravityMagnitudeOutOfRange(0)))
        XCTAssertNil(physiology.acceptedHeartRateBPM)
    }

    func testSignedRRIsPreservedButNeverPromotedWhenImplausible() throws {
        var bytes = capturedV24
        bytes[18] = 1
        bytes[19] = 0xFF
        bytes[20] = 0xFF

        let physiology = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(bytes).decodedRecord?.physiology
        )

        XCTAssertEqual(physiology.decodedRRIntervalsMilliseconds, [-1])
        XCTAssertEqual(physiology.gate, .withheld(.rrIntervalOutOfRange(-1)))
        XCTAssertNil(physiology.acceptedRRIntervalsMilliseconds)
    }

    func testUnknownVersionFailsClosedAndKeepsAllRawBytes() throws {
        var bytes = capturedV24
        bytes[1] = 200

        let failure = try XCTUnwrap(
            AtriaWhoop4HistoricalRecordDecoder.decode(bytes, origin: "fixture").decodeFailure
        )

        XCTAssertEqual(failure.reason, .unsupportedVersion(200))
        XCTAssertEqual(failure.provenance.origin, "fixture")
        XCTAssertEqual(failure.provenance.layoutVersion, 200)
        XCTAssertEqual(failure.provenance.rawBytes, bytes)
    }

    func testMalformedPayloadsFailClosed() throws {
        XCTAssertEqual(
            AtriaWhoop4HistoricalRecordDecoder.decode([]).decodeFailure?.reason,
            .tooShort(actual: 0, required: 2)
        )

        var wrongPacket = capturedV24
        wrongPacket[0] = 0x2E
        XCTAssertEqual(
            AtriaWhoop4HistoricalRecordDecoder.decode(wrongPacket).decodeFailure?.reason,
            .unexpectedPacketType(0x2E)
        )

        var invalidRRCount = capturedV24
        invalidRRCount[18] = 5
        XCTAssertEqual(
            AtriaWhoop4HistoricalRecordDecoder.decode(invalidRRCount).decodeFailure?.reason,
            .invalidRRCount(5)
        )

        XCTAssertEqual(
            AtriaWhoop4HistoricalRecordDecoder.decode(Array(capturedV24.prefix(47)))
                .decodeFailure?.reason,
            .tooShort(actual: 47, required: 48)
        )
    }

    private func replaceFloat32LE(_ value: Float, at offset: Int, in bytes: inout [UInt8]) {
        let bits = value.bitPattern
        bytes[offset] = UInt8(truncatingIfNeeded: bits)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: bits >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: bits >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: bits >> 24)
    }
}

private func historicalHex(_ string: String) -> [UInt8] {
    stride(from: 0, to: string.count, by: 2).compactMap { offset in
        let start = string.index(string.startIndex, offsetBy: offset)
        let end = string.index(start, offsetBy: 2)
        return UInt8(string[start..<end], radix: 16)
    }
}

private extension Array where Element == UInt8 {
    var hexString: String {
        map { String($0, radix: 16).leftPadded(to: 2, with: "0") }.joined()
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
