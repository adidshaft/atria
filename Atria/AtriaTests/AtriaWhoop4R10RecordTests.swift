import XCTest
@testable import Atria

/// Real WHOOP 4 R10/R11 payloads captured on a Mac central on 2026-09-23
/// (tools/strap-mac/r10_capture.py --raw). The fixture holds private biometric
/// data and is intentionally untracked; tests skip when it is absent.
final class AtriaWhoop4R10RecordTests: XCTestCase {
    private struct Segment: Decodable {
        struct ReferenceBout: Decodable {
            let gyro: Double
            let firmware: Int
            let chosen: Double
        }

        let segment: String
        let truth_steps: Int
        let reference_fused_steps: Double
        let reference_bouts: [ReferenceBout]
        let r10_payloads_b64: [String]
        let r11_payloads_b64: [String]
    }

    private static let fixturePath = "Atria/AtriaTests/Fixtures/whoop4-r10-r11-mac-2026-09-23.jsonl"

    private func segments() throws -> [String: Segment] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(Self.fixturePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("private Mac R10/R11 fixture not present: \(Self.fixturePath)")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: Segment] = [:]
        for line in text.split(separator: "\n") where !line.isEmpty {
            let segment = try JSONDecoder().decode(Segment.self, from: Data(line.utf8))
            out[segment.segment] = segment
        }
        return out
    }

    private func frames(_ segment: Segment) throws -> [AtriaWhoop4FusedStepEstimator.Frame] {
        try segment.r10_payloads_b64.map { b64 in
            let payload = [UInt8](try XCTUnwrap(Data(base64Encoded: b64)))
            let record = try XCTUnwrap(AtriaWhoop4R10Record.decode(payload: payload))
            let motion = try XCTUnwrap(AtriaR10MotionDecoder.decode(payload: payload))
            return AtriaWhoop4FusedStepEstimator.Frame(record: record, motion: motion)
        }
    }

    func testRecordMetadataDecodesPhysicallyConsistentFields() throws {
        let walk = try XCTUnwrap(try segments()["w4_100spm"])
        let decoded = try frames(walk)
        XCTAssertGreaterThan(decoded.count, 50)
        for (previous, next) in zip(decoded, decoded.dropFirst()) {
            // Contiguous capture: counter +1, frame period 0.96143 s ± 1 ms.
            XCTAssertEqual(next.record.frameCounter &- previous.record.frameCounter, 1)
            XCTAssertEqual(next.record.deviceTime - previous.record.deviceTime, 0.96143, accuracy: 0.001)
        }
        for frame in decoded {
            let r = frame.record
            XCTAssertTrue((40...200).contains(r.heartRate))
            XCTAssertTrue(r.rrIntervalsMilliseconds.allSatisfy { (300...2_000).contains($0) })
            // Firmware gravity = raw accel mean + a fixed per-strap bias (≤ 0.05 g per axis).
            let n = Double(frame.motion.acceleration.count)
            let mean = (
                frame.motion.acceleration.reduce(0) { $0 + $1.x } / n,
                frame.motion.acceleration.reduce(0) { $0 + $1.y } / n,
                frame.motion.acceleration.reduce(0) { $0 + $1.z } / n
            )
            XCTAssertEqual(r.calibratedGravity.x, mean.0, accuracy: 0.05)
            XCTAssertEqual(r.calibratedGravity.y, mean.1, accuracy: 0.05)
            XCTAssertEqual(r.calibratedGravity.z, mean.2, accuracy: 0.05)
            XCTAssertTrue((250...500).contains(r.skinTemperatureRaw))
            XCTAssertFalse(r.isCharging)
        }
        // HR from RR (ms) agrees with the frame's own bpm field.
        let rr = decoded.flatMap(\.record.rrIntervalsMilliseconds)
        let meanRR = Double(rr.reduce(0, +)) / Double(rr.count)
        let meanHR = Double(decoded.map(\.record.heartRate).reduce(0, +)) / Double(decoded.count)
        XCTAssertEqual(60_000 / meanRR, meanHR, accuracy: 6)
    }

    func testR11DecodesFourSlotsWithTwoActivePPGSlots() throws {
        let walk = try XCTUnwrap(try segments()["w4_100spm"])
        for b64 in walk.r11_payloads_b64 {
            let payload = [UInt8](try XCTUnwrap(Data(base64Encoded: b64)))
            let record = try XCTUnwrap(AtriaWhoop4R11PPGRecord.decode(payload: payload))
            XCTAssertEqual(record.slots.count, 4)
            XCTAssertEqual(record.slots.filter(\.isActive).map(\.index), [0, 3])
            for slot in record.slots where slot.isActive {
                XCTAssertEqual(slot.channels.count, 2)
                XCTAssertTrue(slot.channels.allSatisfy { $0.count == 50 })
                // Signed 20-bit ADC range.
                XCTAssertTrue(slot.channels.joined().allSatisfy { (-524_288...524_287).contains($0) })
            }
        }
    }

    func testFusedEstimatorMatchesPythonReferenceAndRejectsControls() throws {
        let all = try segments()
        for name in ["w4_100spm", "k2_bag", "c2_hand_talk", "c1_typing"] {
            let segment = try XCTUnwrap(all[name])
            let result = AtriaWhoop4FusedStepEstimator.estimate(frames: try frames(segment))
            XCTAssertEqual(result.steps, segment.reference_fused_steps, accuracy: 1.0, name)
            XCTAssertEqual(result.bouts.count, segment.reference_bouts.count, name)
            if segment.truth_steps == 0 {
                XCTAssertEqual(result.steps, 0, "\(name) must not produce steps")
            } else {
                XCTAssertEqual(result.steps, Double(segment.truth_steps),
                               accuracy: Double(segment.truth_steps) * 0.1, name)
            }
        }
        // Bag walk: arm not swinging → firmware counter carries the bout.
        let bag = AtriaWhoop4FusedStepEstimator.estimate(frames: try frames(try XCTUnwrap(all["k2_bag"])))
        XCTAssertEqual(bag.bouts.first?.source, .firmwareCounter)
        let walk = AtriaWhoop4FusedStepEstimator.estimate(frames: try frames(try XCTUnwrap(all["w4_100spm"])))
        XCTAssertEqual(walk.bouts.first?.source, .gyroCadence)
    }

    func testFirmwareStepDeltaIsWrapSafe() {
        XCTAssertEqual(AtriaWhoop4R10Record.firmwareStepDelta(from: 65_530, to: 4), 10)
        XCTAssertEqual(AtriaWhoop4R10Record.firmwareStepDelta(from: 1_700, to: 1_856), 156)
    }

    func testPeriodicityIsHighForRhythmAndZeroForFlatSignal() {
        let rate = AtriaWhoop4R10Record.imuSampleRateHz
        let rhythm = (0..<1_000).map { 1 + 0.2 * sin(2 * Double.pi * 1.7 * Double($0) / rate) }
        XCTAssertGreaterThan(AtriaWhoop4FusedStepEstimator.periodicity(rhythm), 0.8)
        XCTAssertEqual(AtriaWhoop4FusedStepEstimator.periodicity([Double](repeating: 1, count: 1_000)), 0)
    }
}
