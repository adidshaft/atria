import Foundation

@main
enum ReplayStepCalibration {
    private struct CandidateOverride {
        let filterLength: Int
        let peakWindow: Int
        let sensitivityG: Double
        let confirmationSteps: Int
        let referenceGain: Double
    }

    private struct ParsedArguments {
        let directory: URL
        let startMS: Int64
        let endMS: Int64
        let expectedSteps: Int?
        let candidateOverride: CandidateOverride?
    }

    private static let usage = """
    usage: replay_step_calibration <csv-directory> <start-ms> <end-ms> [expected-steps] [--candidate-filter <4|6|8|10|12> --candidate-peak <17|21|25|29|33|37> --candidate-sensitivity <0.04...0.14 by 0.01> --candidate-confirmation <4|6|8|10> --candidate-gain <0.75...1.50>]
    """

    static func main() throws {
        let arguments = parseArguments(CommandLine.arguments)
        let directory = arguments.directory
        let startMS = arguments.startMS
        let endMS = arguments.endMS
        let expectedSteps = arguments.expectedSteps
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "csv" }

        var rows: [(sampleAtMS: Int64, receivedAtMS: Int64, frame: Data)] = []
        for file in files {
            var isHeader = true
            try forEachLine(in: file) { line in
                if isHeader {
                    isHeader = false
                    return
                }
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count >= 6,
                      let receivedAtMS = Int64(columns[1]),
                      let frame = data(hex: columns[5]),
                      let deviceTimestamp = AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: frame),
                      deviceTimestamp > 0 else { return }
                let sampleAtMS = Int64(deviceTimestamp) * 1_000
                guard sampleAtMS >= startMS, sampleAtMS < endMS else { return }
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
        var gaitChallenger = AtriaStrapGaitQualityChallenger()
        var gaitAssessments: [AtriaStrapGaitQualityChallenger.Assessment] = []
        var currentAcceptedGaitSeconds = 0
        var longestAcceptedGaitSeconds = 0
        // Keep a second, explicit representation of the evidence as strictly
        // contiguous device-time segments. The production replay below owns
        // the nuanced isolated-gap policy; these segments are a diagnostic
        // proof that no detector sweep can silently concatenate motion from
        // opposite sides of an unavailable strap second.
        var magnitudeSegments: [[Double]] = []
        var currentMagnitudeSegment: [Double] = []
        var gyroSegments: [[Double]] = []
        var currentGyroSegment: [Double] = []
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
                if !currentGyroSegment.isEmpty {
                    gyroSegments.append(currentGyroSegment)
                    currentGyroSegment.removeAll(keepingCapacity: true)
                }
                _ = gaitChallenger.resetForGap()
                currentAcceptedGaitSeconds = 0
            }
            currentMagnitudeSegment.append(contentsOf: magnitudes)
            currentGyroSegment.append(contentsOf: decoded.rotationRate.map(\.magnitude))
            previousDeviceTimestamp = decoded.deviceTimestamp
            motionFrames.append((decoded.deviceTimestamp, magnitudes))
            let gaitUpdate = gaitChallenger.ingest(acceleration: decoded.acceleration,
                                                   rotationRate: decoded.rotationRate)
            if let assessment = gaitUpdate.assessment {
                gaitAssessments.append(assessment)
                if assessment.verdict == .accepted {
                    currentAcceptedGaitSeconds += 1
                    longestAcceptedGaitSeconds = max(longestAcceptedGaitSeconds,
                                                     currentAcceptedGaitSeconds)
                } else {
                    currentAcceptedGaitSeconds = 0
                }
            }
            finalSnapshot = pipeline.ingestSynchronouslyForTesting(decoded)
        }
        if !currentMagnitudeSegment.isEmpty {
            magnitudeSegments.append(currentMagnitudeSegment)
        }
        if !currentGyroSegment.isEmpty {
            gyroSegments.append(currentGyroSegment)
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
        // Research shadow only — never a production count. See
        // AtriaGyroCadenceResearchPedometer for the physical basis.
        let gyroCadenceResearchSteps = gyroSegments.reduce(0.0) { total, segment in
            total + AtriaGyroCadenceResearchPedometer.steps(
                contiguousRotationMagnitudes: segment
            )
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
        print(String(format: "gyro_cadence_research_steps=%.1f status=research_never_production",
                     gyroCadenceResearchSteps))
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
        print(gaitShadowSummary(assessments: gaitAssessments,
                                longestAcceptedSeconds: longestAcceptedGaitSeconds))
        if let candidate = arguments.candidateOverride {
            guard evidenceIsScoreable else {
                fail("candidate replay refused incomplete motion evidence")
            }
            let candidateRawSteps = rawStepCount(
                motionFrames: motionFrames,
                filterLength: candidate.filterLength,
                peakWindow: candidate.peakWindow,
                sensitivityG: candidate.sensitivityG,
                confirmationSteps: candidate.confirmationSteps
            )
            let candidateSteps = Int((Double(candidateRawSteps) * candidate.referenceGain).rounded())
            print(String(format: "candidate_override=1 filter=%d peak=%d sensitivity=%.2f confirmation=%d gain=%.4f",
                         candidate.filterLength,
                         candidate.peakWindow,
                         candidate.sensitivityG,
                         candidate.confirmationSteps,
                         candidate.referenceGain))
            print("candidate_raw_steps=\(candidateRawSteps) candidate_steps=\(candidateSteps)")
            if let expectedSteps {
                if expectedSteps > 0 {
                    let error = Double(candidateSteps - expectedSteps) / Double(expectedSteps) * 100
                    print(String(format: "candidate_expected_steps=%d scoreable=1 error_pct=%+.1f",
                                 expectedSteps,
                                 error))
                } else {
                    print("candidate_expected_steps=0 scoreable=1 rest_false_steps=\(candidateSteps) rest_pass=\(candidateSteps == 0 ? 1 : 0)")
                }
            }
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

    private static func parseArguments(_ commandLine: [String]) -> ParsedArguments {
        guard commandLine.count >= 4,
              let startMS = Int64(commandLine[2]),
              let endMS = Int64(commandLine[3]),
              startMS <= endMS else {
            fail(usage)
        }

        var index = 4
        var expectedSteps: Int?
        if index < commandLine.count, !commandLine[index].hasPrefix("--") {
            guard let parsed = Int(commandLine[index]), parsed >= 0 else {
                fail("expected-steps must be a nonnegative integer\n\(usage)")
            }
            expectedSteps = parsed
            index += 1
        }

        let allowedFlags = Set([
            "--candidate-filter",
            "--candidate-peak",
            "--candidate-sensitivity",
            "--candidate-confirmation",
            "--candidate-gain",
        ])
        var optionValues: [String: String] = [:]
        while index < commandLine.count {
            let flag = commandLine[index]
            guard allowedFlags.contains(flag) else {
                fail("unknown candidate option: \(flag)\n\(usage)")
            }
            guard optionValues[flag] == nil else {
                fail("duplicate candidate option: \(flag)\n\(usage)")
            }
            guard index + 1 < commandLine.count,
                  !commandLine[index + 1].hasPrefix("--") else {
                fail("missing value for candidate option: \(flag)\n\(usage)")
            }
            optionValues[flag] = commandLine[index + 1]
            index += 2
        }

        let candidateOverride: CandidateOverride?
        if optionValues.isEmpty {
            candidateOverride = nil
        } else {
            guard optionValues.count == allowedFlags.count else {
                fail("candidate override requires all five candidate options\n\(usage)")
            }
            guard let filterText = optionValues["--candidate-filter"],
                  let filterLength = Int(filterText),
                  [4, 6, 8, 10, 12].contains(filterLength) else {
                fail("candidate filter must be one of 4, 6, 8, 10, 12")
            }
            guard let peakText = optionValues["--candidate-peak"],
                  let peakWindow = Int(peakText),
                  [17, 21, 25, 29, 33, 37].contains(peakWindow) else {
                fail("candidate peak must be one of 17, 21, 25, 29, 33, 37")
            }
            guard let sensitivityText = optionValues["--candidate-sensitivity"],
                  let sensitivityG = Double(sensitivityText),
                  sensitivityG.isFinite,
                  sensitivityG >= 0.04,
                  sensitivityG <= 0.14,
                  abs(sensitivityG * 100 - (sensitivityG * 100).rounded()) < 0.000_001 else {
                fail("candidate sensitivity must be a finite 0.01 increment from 0.04 through 0.14")
            }
            guard let confirmationText = optionValues["--candidate-confirmation"],
                  let confirmationSteps = Int(confirmationText),
                  [4, 6, 8, 10].contains(confirmationSteps) else {
                fail("candidate confirmation must be one of 4, 6, 8, 10")
            }
            guard let gainText = optionValues["--candidate-gain"],
                  let referenceGain = Double(gainText),
                  referenceGain.isFinite,
                  referenceGain >= 0.75,
                  referenceGain <= 1.50 else {
                fail("candidate gain must be finite and within 0.75...1.50")
            }
            candidateOverride = CandidateOverride(
                filterLength: filterLength,
                peakWindow: peakWindow,
                sensitivityG: sensitivityG,
                confirmationSteps: confirmationSteps,
                referenceGain: referenceGain
            )
        }

        return ParsedArguments(
            directory: URL(fileURLWithPath: commandLine[1], isDirectory: true),
            startMS: startMS,
            endMS: endMS,
            expectedSteps: expectedSteps,
            candidateOverride: candidateOverride
        )
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

    /// Research-only locomotion diagnostics for labelled physical windows.
    /// These scores never select a production activity label; they make the
    /// future walk/run/dance/strength/cycle/handling confusion matrix
    /// reproducible from the same CRC-valid raw frames used for step fitting.
    private static func gaitShadowSummary(
        assessments: [AtriaStrapGaitQualityChallenger.Assessment],
        longestAcceptedSeconds: Int
    ) -> String {
        let accepted = assessments.filter { $0.verdict == .accepted }
        let ratio = assessments.isEmpty
            ? 0
            : Double(accepted.count) / Double(assessments.count)
        let cadence = median(accepted.map(\.cadenceStepsPerMinute))
        let periodicity = median(accepted.map(\.periodicity))
        let consistency = median(accepted.map(\.cadenceConsistency))
        let gyroValues = accepted.compactMap(\.gyroscopeAgreement)
        let gyro = median(gyroValues)
        return String(
            format: "gait_shadow_overlapping_windows=%d window_s=5 stride_s=1 accepted_overlapping_windows=%d accepted_ratio=%.4f longest_accepted_stride_run_s=%d accepted_cadence_median_spm=%.2f accepted_periodicity_median=%.4f accepted_consistency_median=%.4f accepted_gyro_median=%@ activity_decoder_validated=0 production_label=none",
            assessments.count,
            accepted.count,
            ratio,
            longestAcceptedSeconds,
            cadence ?? -1,
            periodicity ?? -1,
            consistency ?? -1,
            gyro.map { String(format: "%.4f", $0) } ?? "unavailable"
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }

    private static func data(hex: Substring) -> Data? {
        let utf8 = hex.utf8
        guard utf8.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count / 2)
        var iterator = utf8.makeIterator()
        while let highCharacter = iterator.next() {
            guard let lowCharacter = iterator.next(),
                  let high = hexNibble(highCharacter),
                  let low = hexNibble(lowCharacter) else { return nil }
            bytes.append((high << 4) | low)
        }
        return Data(bytes)
    }

    private static func hexNibble(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57: return character - 48
        case 65...70: return character - 55
        case 97...102: return character - 87
        default: return nil
        }
    }

    /// Streams large retained archives instead of materializing every CSV in
    /// memory. A single calibration pull can exceed 90 MB while a requested
    /// window contains only a few matching frames; retaining the whole file
    /// previously allowed the replay process to be killed before it could
    /// report that sparse evidence honestly.
    private static func forEachLine(in file: URL,
                                    _ body: (Substring) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                if let text = String(data: line, encoding: .utf8) {
                    try body(text[...])
                }
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty,
           let text = String(data: pending, encoding: .utf8) {
            try body(text[...])
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
