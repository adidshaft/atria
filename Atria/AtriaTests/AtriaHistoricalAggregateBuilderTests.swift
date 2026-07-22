import XCTest
@testable import Atria

final class AtriaHistoricalAggregateBuilderTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    func testHeartRateHistogramAndTransitionBasisPreserveLoadMathAndGaps() throws {
        let base: UInt32 = 1_800_000_000
        let records = [
            record(unix: base, heartRate: 60),
            record(unix: base + 10, heartRate: 80),
            record(unix: base + 30, heartRate: 100),
        ]
        let aggregate = try AtriaHistoricalAggregateBuilder.build(
            records: records,
            source: source(records: records),
            createdAt: Date(timeIntervalSince1970: TimeInterval(base + 31))
        )

        XCTAssertEqual(aggregate.parity.heartRateSamples, 3)
        XCTAssertEqual(aggregate.parity.heartRateSumBPM, 240)
        let minute = try XCTUnwrap(aggregate.heartRateMinutes.first)
        XCTAssertEqual(minute.samplesByBPM, [60: 1, 80: 1, 100: 1])
        XCTAssertEqual(minute.terminalBPMSeconds, [80: 10])
        XCTAssertEqual(minute.transitionHalfBPMSeconds, [140: 10])
        XCTAssertEqual(minute.coveredSeconds, 10, accuracy: 0.000_001)
        XCTAssertEqual(minute.droppedGapSeconds, 20, accuracy: 0.000_001)

        let rawTRIMP = AtriaAnalytics.Strain.trimp(
            [(t: 0, bpm: 60), (t: 10, bpm: 80), (t: 30, bpm: 100)],
            rest: 50,
            max: 190,
            coefficient: 1.92
        )
        let storedTRIMP = minute.transitionHalfBPMSeconds.reduce(0.0) { total, element in
            let meanBPM = Double(element.key) / 2
            let hrr = min(max((meanBPM - 50) / 140, 0), 1)
            return total + element.value / 60 * hrr * 0.64 * exp(1.92 * hrr)
        }
        XCTAssertEqual(storedTRIMP, rawTRIMP, accuracy: 0.000_000_001)
    }

    func testSemanticReceiptChangesWhenAnyAggregateFactChanges() throws {
        let base: UInt32 = 1_800_000_000
        let firstRecords = [record(unix: base, heartRate: 70), record(unix: base + 1, heartRate: 71)]
        let secondRecords = [record(unix: base, heartRate: 70), record(unix: base + 1, heartRate: 72)]
        let first = try AtriaHistoricalAggregateBuilder.build(records: firstRecords,
                                                               source: source(records: firstRecords),
                                                               createdAt: Date(timeIntervalSince1970: 2_000_000_000))
        let second = try AtriaHistoricalAggregateBuilder.build(records: secondRecords,
                                                                source: source(records: secondRecords),
                                                                createdAt: Date(timeIntervalSince1970: 2_000_000_000))

        XCTAssertNotEqual(AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: first),
                          AtriaHistoricalAggregateBuilder.semanticParityReceipt(for: second))
    }

    func testFileBuilderFailsClosedOnUnknownRow() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("sealed.jsonl")
        try Data("{\"unknown\":true}\n".utf8).write(to: url)

        XCTAssertThrowsError(try AtriaHistoricalAggregateBuilder.build(
            sourceURL: url,
            chunkID: "unknown",
            createdAt: Date()
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalAggregateBuilder.BuildError,
                           .undecodableRows(1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileBuilderRejectsTornTrailingJSONBeforeAnyRetentionCommit() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("sealed.jsonl")
        try Data("{\"partial\":true".utf8).write(to: url)

        XCTAssertThrowsError(try AtriaHistoricalAggregateBuilder.build(
            sourceURL: url,
            chunkID: "torn",
            createdAt: Date()
        )) { error in
            XCTAssertEqual(error as? AtriaHistoricalAggregateBuilder.BuildError,
                           .tornTrailingRow)
        }
    }

    private func source(records: [HistoricalArchive.Record]) -> AtriaHistoricalAggregateChunk.Source {
        let timestamps = records.map {
            Date(timeIntervalSince1970: TimeInterval($0.clockCorrectedUnix7 ?? $0.unix7)
                + TimeInterval($0.subsec11) / 32_768)
        }
        return .init(chunkID: "test-chunk",
                     rawSHA256: String(repeating: "a", count: 64),
                     rawByteCount: 123,
                     rawRowCount: records.count,
                     firstTimestamp: timestamps.min()!,
                     lastTimestamp: timestamps.max()!,
                     decoderSchema: HistoricalArchive.schema,
                     validatedLayouts: [HistoricalArchive.layoutVersion])
    }

    private func record(unix: UInt32, heartRate: Int) -> HistoricalArchive.Record {
        HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                 capturedAt: Date(timeIntervalSince1970: TimeInterval(unix)),
                                 source: "0x2f",
                                 layoutVersion: HistoricalArchive.layoutVersion,
                                 sequence: 24,
                                 command: 0x2f,
                                 unix7: unix,
                                 subsec11: 0,
                                 flash13: unix,
                                 payloadLength: 1,
                                 whoofHR17: heartRate,
                                 whoofRRNum18: 0,
                                 whoofRR19: [],
                                 kRR64: [],
                                 gravityX36: 0,
                                 gravityY40: 0,
                                 gravityZ44: 1,
                                 gravityMagnitude: 1,
                                 gravityValidated: true,
                                 candidateRR: [],
                                 rawPayloadHex: "00",
                                 clockDeviceRef: 1,
                                 clockWallRef: 1,
                                 clockDriftSeconds: 0,
                                 clockCorrectedUnix7: unix,
                                 clockCorrectionStatus: "clock_ref_present",
                                 currentSessionUsable: true,
                                 metricUsable: true,
                                 usabilityReason: "test")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaHistoricalAggregateBuilderTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
