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
        var motionFrames: [(deviceTimestamp: UInt32, magnitudes: [Double])] = []
        motionFrames.reserveCapacity(rows.count)
        // Keep a second, explicit representation of the evidence as strictly
        // contiguous device-time segments. The production replay below owns
        // the nuanced isolated-gap policy; these segments are a diagnostic
        // proof that no detector sweep can silently concatenate motion from
        // opposite sides of an unavailable strap second.
        var magnitudeSegments: [[Double]] = []
        var currentMagnitudeSegment: [Double] = []
        var previousDeviceTimestamp: UInt32?
        var seenDeviceTimestamps = Set<UInt32>()
        for row in rows {
            guard let decoded = AtriaR10MotionDecoder.decode(frame: row.frame) else { continue }
            guard seenDeviceTimestamps.insert(decoded.deviceTimestamp).inserted else {
                duplicateFrames += 1
                continue
            }
            decodedFrames += 1
            let magnitudes = decoded.acceleration.map(\.magnitude)
            if let previousDeviceTimestamp,
               decoded.deviceTimestamp &- previousDeviceTimestamp != 1 {
                if !currentMagnitudeSegment.isEmpty {
                    magnitudeSegments.append(currentMagnitudeSegment)
                    currentMagnitudeSegment.removeAll(keepingCapacity: true)
                }
            }
            currentMagnitudeSegment.append(contentsOf: magnitudes)
            previousDeviceTimestamp = decoded.deviceTimestamp
            motionFrames.append((decoded.deviceTimestamp, magnitudes))
            finalSnapshot = pipeline.ingestSynchronouslyForTesting(decoded)
        }
        if !currentMagnitudeSegment.isEmpty {
            magnitudeSegments.append(currentMagnitudeSegment)
        }

        let expectedFrames = expectedFrameCount(startMS: startMS, endMS: endMS)
        let diagnostics = continuityDiagnostics(timestamps: motionFrames.map(\.deviceTimestamp))
        let missingFrames = max(0, expectedFrames - decodedFrames)
        let coverage = expectedFrames > 0
            ? Double(decodedFrames) / Double(expectedFrames)
            : 0
        // Detector fitting must never absorb missing motion into a sensitivity
        // or gain change. A replay is scoreable only when every expected strap
        // second is present and device time is fully contiguous.
        let evidenceIsScoreable = expectedFrames > 0
            && decodedFrames == expectedFrames
            && diagnostics.continuityBreaks == 0

        let rawSteps = finalSnapshot?.rawSteps ?? 0
        let productionSteps = Int((Double(rawSteps) * AtriaStrapPedometer.referenceGain).rounded())
        let strictSegmentRawSteps = magnitudeSegments.reduce(0) { total, magnitudes in
            total + AtriaStrapPedometer.rawStepCount(magnitudes: magnitudes)
        }
        print("window_ms=\(startMS)...\(endMS)")
        print("archive_rows=\(rows.count) decoded_unique_frames=\(decodedFrames) duplicate_frames=\(duplicateFrames) samples=\(finalSnapshot?.samples ?? 0)")
        print(String(format: "expected_frames=%d missing_frames=%d coverage_pct=%.1f continuity_breaks=%d isolated_missing_seconds=%d long_breaks=%d longest_contiguous_seconds=%d evidence_scoreable=%d",
                     expectedFrames,
                     missingFrames,
                     coverage * 100,
                     diagnostics.continuityBreaks,
                     diagnostics.isolatedMissingSeconds,
                     diagnostics.longBreaks,
                     diagnostics.longestContiguousSeconds,
                     evidenceIsScoreable ? 1 : 0))
        print("raw_steps=\(rawSteps) production_gain=\(AtriaStrapPedometer.referenceGain) production_steps=\(productionSteps)")
        print("strict_contiguous_segments=\(magnitudeSegments.count) strict_segment_raw_steps=\(strictSegmentRawSteps)")
        if let expectedSteps, expectedSteps > 0 {
            if evidenceIsScoreable {
                let error = Double(productionSteps - expectedSteps) / Double(expectedSteps) * 100
                if rawSteps > 0 {
                    let suggestedGain = Double(expectedSteps) / Double(rawSteps)
                    print(String(format: "expected_steps=%d scoreable=1 error_pct=%+.1f suggested_gain=%.4f",
                                 expectedSteps,
                                 error,
                                 suggestedGain))
                } else {
                    print(String(format: "expected_steps=%d scoreable=1 error_pct=%+.1f suggested_gain=unavailable",
                                 expectedSteps,
                                 error))
                }
            } else {
                print("expected_steps=\(expectedSteps) scoreable=0 error_pct=unavailable suggested_gain=unavailable")
            }
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
                    motionFrames: motionFrames,
                    filterLength: AtriaStrapPedometer.filterLength,
                    peakWindow: AtriaStrapPedometer.peakWindow,
                    sensitivityG: sensitivity,
                    confirmationSteps: confirmation
                )
                let gain = suggestedGain(expectedSteps: expectedSteps,
                                         rawSteps: candidate,
                                         evidenceIsScoreable: evidenceIsScoreable)
                print(String(format: "%.2f,%d,%d,%@",
                             sensitivity,
                             confirmation,
                             candidate,
                             gain.map { String(format: "%.4f", $0) } ?? "unavailable"))
            }
        }
        print("candidate_sweep filter,peak_window,sensitivity_g,confirmation_steps,raw_steps,suggested_gain")
        for candidate in [(8, 29, 0.06, 6), (4, 17, 0.06, 6), (6, 21, 0.08, 6), (8, 25, 0.06, 6)] {
            let steps = rawStepCount(
                motionFrames: motionFrames,
                filterLength: candidate.0,
                peakWindow: candidate.1,
                sensitivityG: candidate.2,
                confirmationSteps: candidate.3
            )
            let gain = suggestedGain(expectedSteps: expectedSteps,
                                     rawSteps: steps,
                                     evidenceIsScoreable: evidenceIsScoreable)
            print(String(format: "%d,%d,%.2f,%d,%d,%@",
                         candidate.0,
                         candidate.1,
                         candidate.2,
                         candidate.3,
                         steps,
                         gain.map { String(format: "%.4f", $0) } ?? "unavailable"))
        }
    }

    /// Replays the same gap policy as `AtriaR10MotionPipeline`: one missing
    /// R10 second may retain only already-confirmed gait, while longer gaps
    /// require fresh confirmation. Candidate sweeps therefore remain directly
    /// comparable with the production replay even when diagnostic input has
    /// holes; incomplete evidence is still explicitly marked unscoreable.
    private static func rawStepCount(motionFrames: [(deviceTimestamp: UInt32,
                                                     magnitudes: [Double])],
                                     filterLength: Int,
                                     peakWindow: Int,
                                     sensitivityG: Double,
                                     confirmationSteps: Int) -> Int {
        var detector = AtriaStrapPedometer.StreamingDetector(
            filterLength: filterLength,
            peakWindow: peakWindow,
            sensitivityG: sensitivityG,
            confirmationSteps: confirmationSteps
        )
        var committedSteps = 0
        var previousTimestamp: UInt32?
        for frame in motionFrames {
            if let previousTimestamp {
                let delta = frame.deviceTimestamp &- previousTimestamp
                if delta != 1 {
                    committedSteps += detector.rawSteps
                    if delta == 2 {
                        detector.resetAfterIsolatedMissingSecond()
                    } else {
                        detector.reset()
                    }
                }
            }
            detector.ingest(frame.magnitudes)
            previousTimestamp = frame.deviceTimestamp
        }
        return committedSteps + detector.rawSteps
    }

    private static func expectedFrameCount(startMS: Int64, endMS: Int64) -> Int {
        guard startMS < endMS else { return 0 }
        let firstSecond = (startMS + 999) / 1_000
        let lastSecond = (endMS - 1) / 1_000
        return max(0, Int(lastSecond - firstSecond + 1))
    }

    private static func continuityDiagnostics(
        timestamps: [UInt32]
    ) -> (continuityBreaks: Int,
          isolatedMissingSeconds: Int,
          longBreaks: Int,
          longestContiguousSeconds: Int) {
        guard !timestamps.isEmpty else { return (0, 0, 0, 0) }
        var continuityBreaks = 0
        var isolatedMissingSeconds = 0
        var longBreaks = 0
        var currentRun = 1
        var longestRun = 1
        for (previous, current) in zip(timestamps, timestamps.dropFirst()) {
            let delta = current &- previous
            if delta == 1 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                continuityBreaks += 1
                if delta == 2 {
                    isolatedMissingSeconds += 1
                } else {
                    longBreaks += 1
                }
                currentRun = 1
            }
        }
        return (continuityBreaks,
                isolatedMissingSeconds,
                longBreaks,
                longestRun)
    }

    private static func suggestedGain(expectedSteps: Int?,
                                      rawSteps: Int,
                                      evidenceIsScoreable: Bool) -> Double? {
        guard evidenceIsScoreable,
              let expectedSteps,
              expectedSteps > 0,
              rawSteps > 0 else { return nil }
        return Double(expectedSteps) / Double(rawSteps)
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
