import XCTest
@testable import Atria

final class AtriaStrapCalibrationArchiveTests: XCTestCase {
    func testCanonicalFrameRequiresMotionOpcodeAndValidCRC() {
        let imuFrame = encodeFrame(AtriaIMUDecoder.syntheticRestPayload())
        XCTAssertEqual(AtriaStrapCalibrationArchive.canonicalValidatedMotionFrame(from: imuFrame), imuFrame)

        var r10Payload = [UInt8](repeating: 0, count: 1_288)
        r10Payload[0] = 0x2B
        r10Payload[1] = 0x0A
        let r10Frame = encodeFrame(r10Payload)
        XCTAssertEqual(AtriaStrapCalibrationArchive.canonicalValidatedMotionFrame(from: r10Frame), r10Frame)

        let realtimeFrame = encodeFrame([0x28, 0, 0, 0, 0, 0, 0, 0, 60, 0])
        XCTAssertNil(AtriaStrapCalibrationArchive.canonicalValidatedMotionFrame(from: realtimeFrame))

        let r11Frame = encodeFrame([0x2B, 0x0B] + [UInt8](repeating: 0, count: 1_286))
        XCTAssertNil(AtriaStrapCalibrationArchive.canonicalValidatedMotionFrame(from: r11Frame))

        var corruptFrame = imuFrame
        let finalIndex = corruptFrame.index(before: corruptFrame.endIndex)
        corruptFrame[finalIndex] ^= 0xff
        XCTAssertNil(AtriaStrapCalibrationArchive.canonicalValidatedMotionFrame(from: corruptFrame))
    }

    func testCalibrationWindowPersistsAcrossLaunchesAndExpires() throws {
        let suiteName = "AtriaStrapCalibrationArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let enabledUntil = try XCTUnwrap(AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: [AtriaStrapCalibrationArchive.enableArgument],
            defaults: defaults,
            now: now,
            duration: 3_600
        ))
        XCTAssertEqual(enabledUntil.timeIntervalSince(now), 3_600, accuracy: 0.001)
        XCTAssertEqual(AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: [],
            defaults: defaults,
            now: now.addingTimeInterval(60)
        ), enabledUntil)
        XCTAssertNil(AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: [],
            defaults: defaults,
            now: enabledUntil.addingTimeInterval(1)
        ))

        _ = AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: [AtriaStrapCalibrationArchive.enableArgument],
            defaults: defaults,
            now: now
        )
        XCTAssertNil(AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: [AtriaStrapCalibrationArchive.disableArgument],
            defaults: defaults,
            now: now
        ))
    }

    func testArchiveWritesTruePacketTimestampAndRawStrapFrame() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-calibration-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory,
                                                   flushInterval: 60,
                                                   maximumBufferedBytes: 1_024 * 1_024)
        let receivedAt = Date(timeIntervalSince1970: 1_750_000_000.123)
        let frame = encodeFrame(AtriaIMUDecoder.syntheticShakePayload())

        archive.recordMotionFrame(frame, source: "stream5", receivedAt: receivedAt)
        archive.flushSynchronouslyForTesting()

        let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        let rows = contents.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], "schema_version,received_at_unix_ms,source,packet_type,record_type,raw_frame_hex")
        XCTAssertTrue(rows[1].hasPrefix("2,1750000000123,stream5,33,"))
        XCTAssertTrue(rows[1].hasSuffix(frame.map { String(format: "%02x", $0) }.joined()))

        archive.closeSynchronouslyForTesting()
    }

    func testArchiveDropsInvalidAndNonMotionStrapFrames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-calibration-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory, flushInterval: 60)

        archive.recordMotionFrame(encodeFrame([0x28, 0, 0, 0, 0, 0, 0, 0, 60, 0]),
                                  source: "stream5")
        archive.recordMotionFrame(Data([0x33, 0, 1, 2]), source: "stream5")
        archive.flushSynchronouslyForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        archive.closeSynchronouslyForTesting()
    }

    func testCaptureQualityRequiresContinuousDeviceSecondsAndAlignsManifestBounds() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-quality-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory, flushInterval: 60)

        for second in 100..<160 {
            archive.recordMotionFrame(r10Frame(deviceTimestamp: UInt32(second)),
                                      source: "stream5",
                                      receivedAt: Date(timeIntervalSince1970: Double(second) + 0.2))
        }
        let quality = archive.captureQuality(startMS: 100_000, endMS: 160_000)

        XCTAssertTrue(quality.isReady)
        XCTAssertEqual(quality.decodedFrames, 60)
        XCTAssertEqual(quality.coveragePercent, 100, accuracy: 0.001)
        XCTAssertEqual(quality.continuityBreaks, 0)
        XCTAssertEqual(quality.maximumUncoveredGapMS, 0)
        XCTAssertEqual(quality.alignedStartMS, 100_000)
        XCTAssertEqual(quality.alignedEndMSExclusive, 160_000)
    }

    func testCaptureQualityFailsClosedWhenOneDeviceSecondIsMissing() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-gap-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory, flushInterval: 60)

        for second in 100..<160 where second != 130 {
            archive.recordMotionFrame(r10Frame(deviceTimestamp: UInt32(second)), source: "stream5")
        }
        let quality = archive.captureQuality(startMS: 100_000, endMS: 160_000)

        XCTAssertFalse(quality.isReady)
        XCTAssertEqual(quality.decodedFrames, 59)
        XCTAssertEqual(quality.continuityBreaks, 1)
        XCTAssertEqual(quality.maximumUncoveredGapMS, 1_000)
        XCTAssertTrue(quality.failureSummary.contains("gap"))
    }

    func testCaptureQualityAllowsOnlyPartialSecondBoundaryAlignment() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-boundary-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory, flushInterval: 60)
        for second in 101...160 {
            archive.recordMotionFrame(r10Frame(deviceTimestamp: UInt32(second)), source: "stream5")
        }

        let partialSecond = archive.captureQuality(startMS: 100_250, endMS: 160_750)
        XCTAssertTrue(partialSecond.isReady)
        XCTAssertEqual(partialSecond.maximumUncoveredGapMS, 750)
        XCTAssertEqual(partialSecond.alignedStartMS, 101_000)
        XCTAssertEqual(partialSecond.alignedEndMSExclusive, 161_000)

        let wholeMissingSecond = archive.captureQuality(startMS: 100_000, endMS: 160_750)
        XCTAssertFalse(wholeMissingSecond.isReady)
        XCTAssertEqual(wholeMissingSecond.maximumUncoveredGapMS, 1_000)
    }

    func testArchiveRotatesCurrentFileAndEnforcesTotalByteCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-step-cap-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cap: Int64 = 1_024 * 1_024
        let archive = AtriaStrapCalibrationArchive(directoryURL: directory,
                                                   flushInterval: 60,
                                                   maximumBufferedBytes: 16 * 1_024,
                                                   maximumArchiveBytes: cap)

        for second in 0..<600 {
            archive.recordMotionFrame(r10Frame(deviceTimestamp: UInt32(second)),
                                      source: "stream5",
                                      receivedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(second)))
        }
        archive.closeSynchronouslyForTesting()

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let sizes = try files.map {
            Int64(try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertLessThanOrEqual(sizes.max() ?? 0, cap)
        XCTAssertLessThanOrEqual(sizes.reduce(0, +), cap)
    }

    private func r10Frame(deviceTimestamp: UInt32) -> Data {
        var payload = [UInt8](repeating: 0, count: 1_288)
        payload[0] = AtriaR10MotionDecoder.packetType
        payload[1] = AtriaR10MotionDecoder.recordType
        payload[7] = UInt8(deviceTimestamp & 0xff)
        payload[8] = UInt8((deviceTimestamp >> 8) & 0xff)
        payload[9] = UInt8((deviceTimestamp >> 16) & 0xff)
        payload[10] = UInt8((deviceTimestamp >> 24) & 0xff)
        return encodeFrame(payload)
    }
}
