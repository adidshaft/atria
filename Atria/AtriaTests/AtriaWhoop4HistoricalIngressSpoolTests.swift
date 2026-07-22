import XCTest
@testable import Atria

final class AtriaWhoop4HistoricalIngressSpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaIngressSpoolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testRoundTripPreservesFrameMetadataFrameOrderAcrossReopen() throws {
        let url = directory.appendingPathComponent("ingress.bin")
        let first = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 44)
        try first.append(.frame(payload: [0x2f, 1, 2],
                                clock: .init(device: 10, wall: 17),
                                clockAuthorityEnabled: true))
        try first.append(.metadata(payload: [0x31, 9], phaseGeneration: 44))
        try first.append(.frame(payload: [0x2f, 3],
                                clock: nil,
                                clockAuthorityEnabled: false))
        try first.synchronize()

        let reopened = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 44)
        XCTAssertEqual(reopened.pendingCount, 3)
        XCTAssertEqual(try reopened.popFirst(), .frame(
            payload: [0x2f, 1, 2], clock: .init(device: 10, wall: 17), clockAuthorityEnabled: true))
        XCTAssertEqual(try reopened.popFirst(), .metadata(payload: [0x31, 9], phaseGeneration: 44))
        XCTAssertEqual(try reopened.popFirst(), .frame(
            payload: [0x2f, 3], clock: nil, clockAuthorityEnabled: false))
        XCTAssertNil(try reopened.popFirst())
    }

    func testReopenDropsOnlyTornFinalRecord() throws {
        let url = directory.appendingPathComponent("torn.bin")
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 6)
        try spool.append(.metadata(payload: [0x31], phaseGeneration: 6))
        try spool.synchronize()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x20, 0, 0]))
        try handle.close()

        let reopened = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 6)
        XCTAssertEqual(reopened.pendingCount, 1)
        XCTAssertEqual(try reopened.popFirst(), .metadata(payload: [0x31], phaseGeneration: 6))
    }

    func testHardByteCapFailsClosedBeforeAppendingOverflow() throws {
        let url = directory.appendingPathComponent("cap.bin")
        // Header (16) + one clocked 96-byte frame record (124).
        let spool = try AtriaWhoop4HistoricalIngressSpool(url: url, generation: 1, maximumBytes: 140)
        try spool.append(.frame(payload: Array(repeating: 7, count: 96),
                                clock: .init(device: 1, wall: 2),
                                clockAuthorityEnabled: true))
        XCTAssertThrowsError(try spool.append(.metadata(payload: [0x31], phaseGeneration: 1))) { error in
            XCTAssertEqual(error as? AtriaWhoop4HistoricalIngressSpool.SpoolError, .capacityExceeded)
        }
        XCTAssertEqual(spool.pendingCount, 1)
    }
}
