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

    func testNegativeZeroRoundTripsWithFullParity() throws {
        // JSONEncoder writes Double(-0.0) as `-0`. JSONSerialization used to
        // lose the sign bit here (it reparses `-0` as an integer zero) — the
        // hand-rolled byte parser goes through Double("-0") and preserves
        // it, so even this edge is full byte-parity with JSONDecoder now.
        var record = fullRecord()
        record.unknownMotionScalar32 = -0.0
        try assertParity(try encodedLine(record))
    }

    func testEscapedStringsAndOffsetDatesParity() throws {
        // Exercises the byte parser's escape decoding (quote, backslash,
        // \uXXXX incl. a surrogate pair) and a non-Z zone offset — shapes
        // the archive writer never emits but JSONDecoder would accept.
        var record = fullRecord()
        record.strapIdentifier = "quote\" back\\slash \tñ\u{1F600}"
        try assertParity(try encodedLine(record))
        var line = try encodedLine(fullRecord())
        line = line.replacingOccurrences(of: "\"capturedAt\":\"[^\"]*\"",
                                         with: "\"capturedAt\":\"2026-08-03T23:33:41+05:30\"",
                                         options: .regularExpression)
        XCTAssertTrue(line.contains("+05:30"), "offset fixture must be applied")
        try assertParity(line)
        // Explicit \uXXXX escapes incl. a surrogate pair (😀 = D83D DE00):
        // the writer emits raw UTF-8, so only a hand-written line covers
        // the escape-decoding branch.
        line = line.replacingOccurrences(of: "\"usabilityReason\":\"ok\"",
                                         with: "\"usabilityReason\":\"A\\u0042 \\ud83d\\ude00\"")
        XCTAssertTrue(line.contains("\\ud83d"), "escape fixture must be applied")
        try assertParity(line)
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
