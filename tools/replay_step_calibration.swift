import Foundation

@main
enum ReplayStepCalibration {
    static func main() throws {
        guard CommandLine.arguments.count >= 4,
              let startMS = Int64(CommandLine.arguments[2]),
              let endMS = Int64(CommandLine.arguments[3]),
              startMS <= endMS else {
            FileHandle.standardError.write(Data(
                "usage: replay_step_calibration <csv-directory> <start-ms> <end-ms> [expected-steps]\n".utf8
            ))
            exit(2)
        }

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let expectedSteps = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) : nil
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "csv" }

        var rows: [(sampleAtMS: Int64, receivedAtMS: Int64, frame: Data)] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count >= 6,
                      let receivedAtMS = Int64(columns[1]),
                      let frame = data(hex: columns[5]),
                      let decoded = AtriaR10MotionDecoder.decode(frame: frame),
                      decoded.deviceTimestamp > 0 else { continue }
                let sampleAtMS = Int64(decoded.deviceTimestamp) * 1_000
                guard sampleAtMS >= startMS, sampleAtMS < endMS else { continue }
                rows.append((sampleAtMS, receivedAtMS, frame))
            }
        }
        rows.sort {
            if $0.sampleAtMS != $1.sampleAtMS { return $0.sampleAtMS < $1.sampleAtMS }
            return $0.receivedAtMS < $1.receivedAtMS
        }

        let pipeline = AtriaR10MotionPipeline(gain: 1)
        var decodedFrames = 0
        var duplicateFrames = 0
        var finalSnapshot: AtriaR10MotionPipeline.Snapshot?
        var magnitudeSegments: [[Double]] = []
        var activeMagnitudes: [Double] = []
        activeMagnitudes.reserveCapacity(rows.count * AtriaR10MotionDecoder.sampleCount)
        var seenDeviceTimestamps = Set<UInt32>()
        var previousDeviceTimestamp: UInt32?
        for row in rows {
            guard let decoded = AtriaR10MotionDecoder.decode(frame: row.frame) else { continue }
            guard seenDeviceTimestamps.insert(decoded.deviceTimestamp).inserted else {
                duplicateFrames += 1
                continue
            }
            if let previousDeviceTimestamp,
               decoded.deviceTimestamp &- previousDeviceTimestamp != 1 {
                if !activeMagnitudes.isEmpty {
                    magnitudeSegments.append(activeMagnitudes)
                    activeMagnitudes = []
                }
            }
            decodedFrames += 1
            activeMagnitudes.append(contentsOf: decoded.acceleration.map(\.magnitude))
            previousDeviceTimestamp = decoded.deviceTimestamp
            finalSnapshot = pipeline.ingestSynchronouslyForTesting(decoded)
        }
        if !activeMagnitudes.isEmpty {
            magnitudeSegments.append(activeMagnitudes)
        }

        let rawSteps = finalSnapshot?.rawSteps ?? 0
        let productionSteps = Int((Double(rawSteps) * AtriaStrapPedometer.referenceGain).rounded())
        print("window_ms=\(startMS)...\(endMS)")
        print("archive_rows=\(rows.count) decoded_unique_frames=\(decodedFrames) duplicate_frames=\(duplicateFrames) samples=\(finalSnapshot?.samples ?? 0)")
        print("raw_steps=\(rawSteps) production_gain=\(AtriaStrapPedometer.referenceGain) production_steps=\(productionSteps)")
        if let expectedSteps, expectedSteps > 0 {
            let suggestedGain = Double(expectedSteps) / Double(max(rawSteps, 1))
            let error = Double(productionSteps - expectedSteps) / Double(expectedSteps) * 100
            print(String(format: "expected_steps=%d error_pct=%+.1f suggested_gain=%.4f",
                         expectedSteps,
                         error,
                         suggestedGain))
        }
        if let snapshot = finalSnapshot {
            print(String(format: "stillness_ratio=%.4f movement_intensity=%.4f activity_bursts=%d gravity_validated_frames=%d state=%@",
                         snapshot.stillnessRatio,
                         snapshot.movementIntensity,
                         snapshot.activityBursts,
                         snapshot.gravityValidatedFrames,
                         snapshot.state))
        }
        print("threshold_sweep sensitivity_g,confirmation_steps,raw_steps,suggested_gain")
        for sensitivity in stride(from: 0.04, through: 0.16, by: 0.02) {
            for confirmation in [4, 6, 8] {
                let candidate = rawStepCount(
                    magnitudeSegments: magnitudeSegments,
                    filterLength: AtriaStrapPedometer.filterLength,
                    peakWindow: AtriaStrapPedometer.peakWindow,
                    sensitivityG: sensitivity,
                    confirmationSteps: confirmation
                )
                let gain = expectedSteps.map { Double($0) / Double(max(candidate, 1)) } ?? 0
                print(String(format: "%.2f,%d,%d,%.4f", sensitivity, confirmation, candidate, gain))
            }
        }
        print("candidate_sweep filter,peak_window,sensitivity_g,confirmation_steps,raw_steps,suggested_gain")
        for candidate in [(8, 29, 0.06, 6), (4, 17, 0.06, 6), (6, 21, 0.08, 6), (8, 25, 0.06, 6)] {
            let steps = rawStepCount(
                magnitudeSegments: magnitudeSegments,
                filterLength: candidate.0,
                peakWindow: candidate.1,
                sensitivityG: candidate.2,
                confirmationSteps: candidate.3
            )
            let gain = expectedSteps.map { Double($0) / Double(max(steps, 1)) } ?? 0
            print(String(format: "%d,%d,%.2f,%d,%d,%.4f",
                         candidate.0, candidate.1, candidate.2, candidate.3, steps, gain))
        }
    }

    private static func rawStepCount(magnitudeSegments: [[Double]],
                                     filterLength: Int,
                                     peakWindow: Int,
                                     sensitivityG: Double,
                                     confirmationSteps: Int) -> Int {
        magnitudeSegments.reduce(0) { total, magnitudes in
            total + AtriaStrapPedometer.rawStepCount(
                magnitudes: magnitudes,
                filterLength: filterLength,
                peakWindow: peakWindow,
                sensitivityG: sensitivityG,
                confirmationSteps: confirmationSteps
            )
        }
    }

    private static func data(hex: Substring) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
