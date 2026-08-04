import XCTest
@testable import Atria

/// Golden parity for the 2026-08-04 scan-parser swap: the recovered-data scan
/// parses archive lines with `Record(scanLine:)` (JSONSerialization) instead
/// of JSONDecoder, because JSONDecoder retains live memory per decode on the
/// device's iOS 27.0 beta. These tests pin the two parsers to byte-identical
/// results so the swap can never silently change what the scan reads.
/// When `HistoricalArchive.Record` gains or changes a field, extend BOTH
/// parsers and the fixtures here.
final class AtriaRecordScanParserParityTests: XCTestCase {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Both parsers must agree on acceptance, and accepted records must
    /// re-encode to identical canonical JSON (which compares every field,
    /// including optionals and the iso8601 date, without Equatable).
    private func assertParity(_ line: String,
                              file: StaticString = #filePath,
                              lineNumber: UInt = #line) throws {
        let data = Data(line.utf8)
        let codableRecord = try? Self.decoder.decode(HistoricalArchive.Record.self, from: data)
        let scanRecord = HistoricalArchive.Record(scanLine: data)
        switch (codableRecord, scanRecord) {
        case (nil, nil):
            return
        case (nil, .some):
            XCTFail("scan parser accepted a line JSONDecoder rejects: \(line)",
                    file: file, line: lineNumber)
        case (.some, nil):
            XCTFail("scan parser rejected a line JSONDecoder accepts: \(line)",
                    file: file, line: lineNumber)
        case (.some(let codable), .some(let scanned)):
            let codableJSON = try Self.canonicalEncoder.encode(codable)
            let scannedJSON = try Self.canonicalEncoder.encode(scanned)
            XCTAssertEqual(String(decoding: codableJSON, as: UTF8.self),
                           String(decoding: scannedJSON, as: UTF8.self),
                           file: file, line: lineNumber)
        }
    }

    /// A fully-populated record shaped like a real v24 archive row.
    private func fullRecord() -> HistoricalArchive.Record {
        HistoricalArchive.Record(
            schema: 3,
            capturedAt: Date(timeIntervalSince1970: 1_785_780_123),
            strapIdentifier: "C8:5C:11:22:33:44",
            source: "history",
            layoutVersion: "v24",
            sequence: 24,
            command: 70,
            unix7: 1_785_780_120,
            subsec11: 512,
            flash13: 9_912_345,
            payloadLength: 96,
            whoofHR17: 58,
            whoofRRNum18: 3,
            whoofRR19: [1012, 998, 1005],
            kRR64: [1012, 998],
            gravityX36: -0.0123,
            gravityY40: 0.9876,
            gravityZ44: 0.1102,
            unknownMotionScalar32: 4.5,
            gravityMagnitude: 0.9938,
            gravityValidated: true,
            motionTickCounter88: 48_211,
            candidateRR: ["1012@0", "998@1"],
            rawPayloadHex: "18465c00aa07",
            clockDeviceRef: 1_785_780_000,
            clockWallRef: 1_785_780_002,
            clockDriftSeconds: -2,
            clockCorrectedUnix7: 1_785_780_118,
            clockCorrectionStatus: "clock_ref_present",
            currentSessionUsable: true,
            metricUsable: true,
            usabilityReason: "ok")
    }

    /// A minimal record: every optional nil (JSONEncoder omits the keys).
    private func minimalRecord() -> HistoricalArchive.Record {
        HistoricalArchive.Record(
            schema: 3,
            capturedAt: Date(timeIntervalSince1970: 1_785_700_000),
            strapIdentifier: nil,
            source: "live",
            layoutVersion: "v18",
            sequence: 18,
            command: 70,
            unix7: 1_785_699_998,
            subsec11: 0,
            flash13: 12,
            payloadLength: 20,
            whoofHR17: 0,
            whoofRRNum18: 0,
            whoofRR19: [],
            kRR64: [],
            gravityX36: nil,
            gravityY40: nil,
            gravityZ44: nil,
            unknownMotionScalar32: nil,
            gravityMagnitude: nil,
            gravityValidated: false,
            motionTickCounter88: nil,
            candidateRR: [],
            rawPayloadHex: "00",
            clockDeviceRef: nil,
            clockWallRef: nil,
            clockDriftSeconds: nil,
            clockCorrectedUnix7: nil,
            clockCorrectionStatus: "no_clock_ref",
            currentSessionUsable: false,
            metricUsable: false,
            usabilityReason: "no_rr")
    }

    private func encodedLine(_ record: HistoricalArchive.Record) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    func testRoundTripParityFullyPopulated() throws {
        try assertParity(try encodedLine(fullRecord()))
    }

    func testRoundTripParityAllOptionalsAbsent() throws {
        try assertParity(try encodedLine(minimalRecord()))
    }

    func testHandWrittenLineWithNullsAndUnknownKeys() throws {
        // Explicit JSON nulls for optionals + an unknown key: JSONDecoder
        // treats null as absent and ignores unknown keys; the scan parser
        // must match both behaviors.
        try assertParity("""
        {"schema":3,"capturedAt":"2026-08-03T23:33:41Z","source":"history",\
        "layoutVersion":"v24","sequence":24,"command":70,"unix7":1785780120,\
        "subsec11":11,"flash13":41,"payloadLength":96,"whoofHR17":61,\
        "whoofRRNum18":1,"whoofRR19":[984],"kRR64":[],"gravityX36":null,\
        "gravityY40":null,"gravityZ44":null,"gravityMagnitude":null,\
        "gravityValidated":false,"candidateRR":[],"rawPayloadHex":"18",\
        "clockDeviceRef":null,"clockWallRef":null,"clockDriftSeconds":null,\
        "clockCorrectedUnix7":null,"clockCorrectionStatus":"no_clock_ref",\
        "currentSessionUsable":true,"metricUsable":true,\
        "usabilityReason":"ok","someFutureKey":"ignored"}
        """)
    }

    func testBothRejectMissingRequiredKey() throws {
        // capturedAt absent — required by both parsers.
        try assertParity("""
        {"schema":3,"source":"history","layoutVersion":"v24","sequence":24,\
        "command":70,"unix7":1785780120,"subsec11":11,"flash13":41,\
        "payloadLength":96,"whoofHR17":61,"whoofRRNum18":1,"whoofRR19":[984],\
        "kRR64":[],"gravityValidated":false,"candidateRR":[],\
        "rawPayloadHex":"18","clockCorrectionStatus":"no_clock_ref",\
        "currentSessionUsable":true,"metricUsable":true,"usabilityReason":"ok"}
        """)
    }

    func testBothRejectMalformedLine() throws {
        try assertParity("{\"schema\":3,\"capturedAt\":\"2026-08-0")
        try assertParity("")
    }

    func testBothRejectWrongTypeOnPresentOptional() throws {
        // motionTickCounter88 present but a string: JSONDecoder throws
        // typeMismatch (rejecting the record); the scan parser must reject
        // too rather than silently reading nil.
        var line = try encodedLine(fullRecord())
        line = line.replacingOccurrences(of: "\"motionTickCounter88\":48211",
                                         with: "\"motionTickCounter88\":\"48211\"")
        XCTAssertTrue(line.contains("\"motionTickCounter88\":\"48211\""),
                      "fixture must actually contain the corrupted key")
        try assertParity(line)
    }

    func testNegativeZeroIsTheOneKnownBenignDivergence() throws {
        // JSONEncoder writes Double(-0.0) as `-0`; JSONSerialization reparses
        // that literal as an INTEGER zero (sign bit lost) while JSONDecoder
        // preserves the minus. IEEE -0.0 == 0.0, so every numeric consumer
        // (gravity math, thresholds, magnitudes) is unaffected — this test
        // pins the divergence as understood and bounds it to the sign bit.
        var record = fullRecord()
        record.unknownMotionScalar32 = -0.0
        let data = Data(try encodedLine(record).utf8)
        let codable = try Self.decoder.decode(HistoricalArchive.Record.self, from: data)
        guard let scanned = HistoricalArchive.Record(scanLine: data) else {
            XCTFail("scan parser must accept a -0.0 line")
            return
        }
        XCTAssertEqual(codable.unknownMotionScalar32, scanned.unknownMotionScalar32,
                       "numeric equality must hold even where the sign bit differs")
        XCTAssertEqual(codable.unknownMotionScalar32?.sign, .minus)
        XCTAssertEqual(scanned.unknownMotionScalar32?.sign, .plus,
                       "if this starts preserving the sign, the divergence is gone — "
                       + "fold this case back into the byte-parity matrix")
    }

    func testParityAcrossRepresentativeVariations() throws {
        // Sweep a matrix of realistic field variations through both parsers.
        var record = fullRecord()
        for (index, hr) in [0, 30, 61, 240].enumerated() {
            record = HistoricalArchive.Record(
                schema: 3,
                capturedAt: Date(timeIntervalSince1970: 1_785_780_123 + TimeInterval(index * 60)),
                strapIdentifier: index % 2 == 0 ? "C8:5C:11:22:33:44" : nil,
                source: index % 2 == 0 ? "history" : "live",
                layoutVersion: "v24",
                sequence: 24,
                command: 70,
                unix7: UInt32(1_785_780_120 + index),
                subsec11: UInt16(index * 1000),
                flash13: UInt32(41 + index),
                payloadLength: 96,
                whoofHR17: hr,
                whoofRRNum18: index,
                whoofRR19: Array(repeating: 950 + index, count: index),
                kRR64: index > 1 ? [950 + index] : [],
                gravityX36: index % 2 == 0 ? Double(index + 1) * -0.25 : nil,
                gravityY40: index % 2 == 0 ? 0.5 : nil,
                gravityZ44: index % 2 == 0 ? 0.75 : nil,
                unknownMotionScalar32: index == 3 ? 12.75 : nil,
                gravityMagnitude: index % 2 == 0 ? 0.99 : nil,
                gravityValidated: index % 2 == 0,
                motionTickCounter88: index == 0 ? nil : index * 1_000,
                candidateRR: index > 0 ? ["\(950 + index)@0"] : [],
                rawPayloadHex: "18465c00aa07",
                clockDeviceRef: index % 2 == 0 ? UInt32(1_785_780_000) : nil,
                clockWallRef: index % 2 == 0 ? UInt32(1_785_780_002) : nil,
                clockDriftSeconds: index % 2 == 0 ? 2 - index : nil,
                clockCorrectedUnix7: index % 2 == 0 ? UInt32(1_785_780_118) : nil,
                clockCorrectionStatus: index % 2 == 0 ? "clock_ref_present" : "no_clock_ref",
                currentSessionUsable: true,
                metricUsable: index != 1,
                usabilityReason: index != 1 ? "ok" : "hr_zero")
            try assertParity(try encodedLine(record))
        }
    }
}
