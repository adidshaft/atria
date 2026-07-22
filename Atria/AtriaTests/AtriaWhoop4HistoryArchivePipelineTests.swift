import XCTest
@testable import Atria

final class AtriaWhoop4HistoryArchivePipelineTests: XCTestCase {
    private lazy var capturedV24 = bytes(
        "2f1805444931019a76316a983a80545e015402cd02e802000000000000f760ff80" +
        "1b153cd763c9bd3313b9bd9a21833f00008245d763c9bd3313b9bd9a21833f5a" +
        "02cc021904ca0261019009010c020c3000000000000001306a000000000000"
    )

    func testVerifiedV24ClockProducesMetricUsableRecord() throws {
        let unix: UInt32 = 1_781_626_522
        let result = AtriaWhoop4HistoryArchivePipeline.prepare(
            payload: capturedV24,
            clock: .init(device: unix,
                         wall: unix,
                         driftSeconds: 0,
                         snappedDriftSeconds: 0),
            historyClockSyncEnabled: true,
            now: Date(timeIntervalSince1970: TimeInterval(unix + 60))
        )

        guard case .record(let record) = result.payload else {
            return XCTFail("expected decoded record")
        }
        XCTAssertTrue(record.metricUsable)
        XCTAssertTrue(record.currentSessionUsable)
        XCTAssertEqual(record.clockCorrectionStatus, "clock_ref_present")
        XCTAssertEqual(record.clockCorrectedUnix7, unix)
        XCTAssertEqual(record.whoofHR17, 84)
        XCTAssertEqual(record.whoofRR19, [717, 744])
    }

    func testMissingClockRetainsRawRecordButWithholdsMetricPromotion() throws {
        let result = AtriaWhoop4HistoryArchivePipeline.prepare(
            payload: capturedV24,
            clock: nil,
            historyClockSyncEnabled: true
        )

        guard case .record(let record) = result.payload else {
            return XCTFail("expected decoded record")
        }
        XCTAssertFalse(record.metricUsable)
        XCTAssertEqual(record.clockCorrectionStatus, "clock_ref_missing")
        XCTAssertNil(record.clockCorrectedUnix7)
        XCTAssertEqual(record.rawPayloadHex, capturedV24.hexString)
    }

    func testUnknownLayoutIsArchivedAsUndecodableWithoutInventedFields() {
        var unknown = capturedV24
        unknown[1] = 200

        let result = AtriaWhoop4HistoryArchivePipeline.prepare(
            payload: unknown,
            clock: nil,
            historyClockSyncEnabled: true
        )

        guard case .undecodable(let payload, let reason) = result.payload else {
            return XCTFail("expected fail-closed undecodable payload")
        }
        XCTAssertEqual(payload, unknown)
        XCTAssertTrue(reason.contains("unsupportedVersion"))
    }

    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).compactMap { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        }
    }
}

private extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
