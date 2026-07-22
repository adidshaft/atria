import XCTest
@testable import Atria

final class AtriaWhoop4HistoryResearchProtocolTests: XCTestCase {
    private typealias Research = AtriaWhoop4HistoryResearchProtocol

    func testCommandResponseSeparatesResponseAndRequestSequences() throws {
        let response = try Research.parseCommandResponse([
            0x24, 0x9f, 0x0b, 0x04, 0x01, 0xe3, 0xa1, 0x5b, 0x6a,
        ])
        XCTAssertEqual(response.responseSequence, 0x9f)
        XCTAssertEqual(response.commandEcho, 0x0b)
        XCTAssertEqual(response.requestSequenceEcho, 0x04)
        XCTAssertEqual(response.data, [0x01, 0xe3, 0xa1, 0x5b, 0x6a])
    }

    func testClockObservationMatchesPhysicalWhoop4Fixture() throws {
        let response = try Research.parseClockObservation([
            0x24, 0x9f, 0x0b, 0x04, 0x01, 0xe3, 0xa1, 0x5b,
            0x6a, 0x88, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        XCTAssertEqual(response.responseSequence, 0x9f)
        XCTAssertEqual(response.requestSequenceEcho, 0x04)
        XCTAssertEqual(response.observedPrefix, 0x01)
        XCTAssertEqual(response.deviceUnix, 1_784_390_115)
        XCTAssertEqual(response.opaqueTail, [0x88, 0x74, 0, 0, 0, 0, 0])
    }

    func testHistoryStartClockMatchesSamePhysicalAttempt() throws {
        let observation = try Research.parseHistoryStartClockObservation([
            0x31, 0xa1, 0x01, 0xe4, 0xa1, 0x5b, 0x6a,
            0x70, 0x7c, 0x06, 0x00, 0x00,
        ])
        XCTAssertEqual(observation.metadataSequence, 0xa1)
        XCTAssertEqual(observation.deviceUnix, 1_784_390_116)
        XCTAssertEqual(observation.opaqueTail, [0x70, 0x7c, 0x06, 0x00, 0x00])
    }

    func testAttemptClockRequiresBothRequestSequenceEchoes() {
        let clock: [UInt8] = [
            0x24, 0x9f, 0x0b, 0x04, 0x01, 0xe3, 0xa1, 0x5b,
            0x6a, 0x88, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let historyResponse: [UInt8] = [0x24, 0xa0, 0x16, 0x05, 0x02, 0x0b, 0, 0]
        let historyStart: [UInt8] = [
            0x31, 0xa1, 0x01, 0xe4, 0xa1, 0x5b, 0x6a,
            0x70, 0x7c, 0x06, 0x00, 0x00,
        ]

        let bound = Research.bindAttemptClock(
            clockRequestSequence: 0x04,
            historyRequestSequence: 0x05,
            clockResponseBytes: clock,
            historyResponseBytes: historyResponse,
            historyStartBytes: historyStart
        )
        XCTAssertEqual(bound?.clockResponseSequence, 0x9f)
        XCTAssertEqual(bound?.historyResponseSequence, 0xa0)
        XCTAssertEqual(bound?.historyMetadataSequence, 0xa1)
        XCTAssertEqual(bound?.deviceClockAdvanceSeconds, 1)

        XCTAssertNil(Research.bindAttemptClock(
            clockRequestSequence: 0x03,
            historyRequestSequence: 0x05,
            clockResponseBytes: clock,
            historyResponseBytes: historyResponse,
            historyStartBytes: historyStart
        ))
        XCTAssertNil(Research.bindAttemptClock(
            clockRequestSequence: 0x04,
            historyRequestSequence: 0x06,
            clockResponseBytes: clock,
            historyResponseBytes: historyResponse,
            historyStartBytes: historyStart
        ))
    }

    func testAttemptClockRejectsStaleOrUnorderedMetadataClock() {
        let clock: [UInt8] = [
            0x24, 0x9f, 0x0b, 0x04, 0x01, 0xe3, 0xa1, 0x5b,
            0x6a, 0x88, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        let historyResponse: [UInt8] = [0x24, 0xa0, 0x16, 0x05, 0x02, 0x0b, 0, 0]
        let earlierStart: [UInt8] = [
            0x31, 0xa1, 0x01, 0xe2, 0xa1, 0x5b, 0x6a,
        ]
        XCTAssertNil(Research.bindAttemptClock(
            clockRequestSequence: 0x04,
            historyRequestSequence: 0x05,
            clockResponseBytes: clock,
            historyResponseBytes: historyResponse,
            historyStartBytes: earlierStart
        ))
    }

    func testDataRangeObservationExtractsOnlyLiteralRecords() throws {
        var body = [UInt8](repeating: 0xaa, count: 66)
        body.replaceSubrange(40..<48, with: [
            0x74, 0x51, 0xc9, 0x69, 0x90, 0x36, 0x00, 0x00,
        ])
        body.replaceSubrange(48..<56, with: [
            0x99, 0x51, 0xc9, 0x69, 0x48, 0x75, 0x00, 0x00,
        ])
        body.replaceSubrange(56..<64, with: [
            0x3b, 0x44, 0x2d, 0x6a, 0xa0, 0x0a, 0x00, 0x00,
        ])
        let bytes = [UInt8]([0x24, 0x88, 0x22, 0x09, 0x01, 0x01]) + body
        let observation = try Research.parseDataRangeObservation(bytes)

        XCTAssertEqual(observation.requestSequenceEcho, 0x09)
        XCTAssertEqual(observation.observedPrefix, [0x01, 0x01])
        XCTAssertEqual(observation.body.count, 66)
        XCTAssertEqual(observation.records.map(\.bodyOffset), [40, 48, 56])
        XCTAssertEqual(observation.records.map(\.unixCandidate), [
            1_774_801_268,
            1_774_801_305,
            1_781_351_483,
        ])
        XCTAssertEqual(observation.records.map(\.opaqueWord), [13_968, 30_024, 2_720])
    }

    func testDataRangeObservationRejectsShortOrWrongCommandResponses() {
        XCTAssertThrowsError(try Research.parseDataRangeObservation([
            0x24, 0x88, 0x21, 0x09, 0x01, 0x01,
        ]))
        XCTAssertThrowsError(try Research.parseDataRangeObservation([
            0x24, 0x88, 0x22, 0x09, 0x01, 0x01, 0xaa,
        ]))
    }
}
