import Foundation

private struct CalibrationManifest: Decodable {
    struct Window: Decodable {
        enum Kind: String, Decodable {
            case walk
            case rest
        }

        let label: String
        let kind: Kind
        let startMS: Int64
        let endMS: Int64
        let expectedSteps: Int

        enum CodingKeys: String, CodingKey {
            case label
            case kind
            case startMS = "start_ms"
            case endMS = "end_ms"
            case expectedSteps = "expected_steps"
        }
    }

    let windows: [Window]
}

private struct Candidate {
    let filterLength: Int
    let peakWindow: Int
    let sensitivityG: Double
    let confirmationSteps: Int
}

private struct WindowEvidence {
    let manifest: CalibrationManifest.Window
    let decodedFrames: Int
    let deviceTimestampsMS: [Int64]
    let magnitudes: [Double]

    var durationSeconds: Double {
        Double(max(0, manifest.endMS - manifest.startMS)) / 1_000
    }

    var coverage: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(1, Double(decodedFrames) / durationSeconds)
    }

    var continuityBreaks: Int {
        zip(deviceTimestampsMS, deviceTimestampsMS.dropFirst()).reduce(0) {
            $0 + ($1.1 == $1.0 + 1_000 ? 0 : 1)
        }
    }

    var maximumUncoveredGapMS: Int64 {
        guard let first = deviceTimestampsMS.first,
              let last = deviceTimestampsMS.last else {
            return max(0, manifest.endMS - manifest.startMS)
        }
        var maximum = max(0, first - manifest.startMS)
        for (previous, current) in zip(deviceTimestampsMS, deviceTimestampsMS.dropFirst()) {
            maximum = max(maximum, max(0, current - previous - 1_000))
        }
        return max(maximum, max(0, manifest.endMS - (last + 1_000)))
    }

    var isCalibrationReady: Bool {
        coverage >= 0.95
            && continuityBreaks == 0
            && maximumUncoveredGapMS == 0
    }
}

private struct CandidateResult {
    let candidate: Candidate
    let gain: Double
    let counts: [Int]
    let meanWalkError: Double
    let maxWalkError: Double
    let restFalseSteps: Int

    var score: Double {
        meanWalkError + maxWalkError * 0.75 + Double(restFalseSteps) * 0.25
    }

    var passes: Bool {
        restFalseSteps == 0 && meanWalkError <= 0.03 && maxWalkError <= 0.05
    }
}

@main
enum FitStepCalibration {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fail("usage: fit_step_calibration <csv-directory> <manifest.json>")
        }

        let archiveDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let manifest = try JSONDecoder().decode(
            CalibrationManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let requiredContract: [(String, CalibrationManifest.Window.Kind, Int)] = [
            ("Rest before", .rest, 0),
            ("Slow 100", .walk, 100),
            ("Normal 100", .walk, 100),
            ("Brisk 100", .walk, 100),
            ("Normal 200", .walk, 200),
            ("Rest after", .rest, 0),
        ]
        guard manifest.windows.count == requiredContract.count,
              zip(manifest.windows, requiredContract).allSatisfy({ pair in
                  let (window, required) = pair
                  return window.label == required.0
                      && window.kind == required.1
                      && window.expectedSteps == required.2
              }) else {
            fail("manifest must contain the exact six-stage guided calibration sequence")
        }
        for window in manifest.windows {
            guard window.startMS < window.endMS,
                  window.expectedSteps >= 0,
                  (window.kind == .walk ? window.expectedSteps > 0 : window.expectedSteps == 0),
                  window.kind != .rest || window.endMS - window.startMS >= 60_000 else {
                fail("invalid window: \(window.label)")
            }
        }
        for (previous, next) in zip(manifest.windows, manifest.windows.dropFirst()) {
            guard previous.endMS <= next.startMS else {
                fail("windows must be chronological and non-overlapping: \(previous.label), \(next.label)")
            }
        }
        for (index, window) in manifest.windows.enumerated() {
            for other in manifest.windows.dropFirst(index + 1) where window.startMS < other.endMS
                && other.startMS < window.endMS {
                fail("overlapping windows: \(window.label) and \(other.label)")
            }
        }

        let evidence = try loadEvidence(directory: archiveDirectory, windows: manifest.windows)
        var evidenceIsComplete = true
        print("evidence")
        for window in evidence {
            print(String(format: "%@ kind=%@ expected=%d frames=%d duration_s=%.1f coverage=%.1f%% breaks=%d max_gap_ms=%lld ready=%d",
                         window.manifest.label,
                         window.manifest.kind.rawValue,
                         window.manifest.expectedSteps,
                         window.decodedFrames,
                         window.durationSeconds,
                         window.coverage * 100,
                         window.continuityBreaks,
                         window.maximumUncoveredGapMS,
                         window.isCalibrationReady ? 1 : 0))
            if !window.isCalibrationReady {
                evidenceIsComplete = false
            }
        }
        guard evidenceIsComplete else {
            fail("invalid motion evidence: every window requires >=95% coverage, contiguous device seconds, and zero uncovered boundary time")
        }

        var results: [CandidateResult] = []
        for filterLength in [4, 6, 8, 10, 12] {
            for peakWindow in [17, 21, 25, 29, 33, 37] {
                for sensitivityHundredths in 4...14 {
                    for confirmationSteps in [4, 6, 8, 10] {
                        let candidate = Candidate(filterLength: filterLength,
                                                  peakWindow: peakWindow,
                                                  sensitivityG: Double(sensitivityHundredths) / 100,
                                                  confirmationSteps: confirmationSteps)
                        results.append(evaluate(candidate: candidate, evidence: evidence))
                    }
                }
            }
        }
        results.sort {
            if $0.passes != $1.passes { return $0.passes && !$1.passes }
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.restFalseSteps != $1.restFalseSteps { return $0.restFalseSteps < $1.restFalseSteps }
            return $0.maxWalkError < $1.maxWalkError
        }

        print("\nranked_candidates")
        for (rank, result) in results.prefix(20).enumerated() {
            let counts = zip(evidence, result.counts)
                .map { "\($0.manifest.label)=\($1)" }
                .joined(separator: ",")
            print(String(format: "%02d pass=%d filter=%d peak=%d sensitivity=%.2f confirmation=%d gain=%.4f mean_walk_error=%.2f%% max_walk_error=%.2f%% rest_false_steps=%d score=%.4f counts=%@",
                         rank + 1,
                         result.passes ? 1 : 0,
                         result.candidate.filterLength,
                         result.candidate.peakWindow,
                         result.candidate.sensitivityG,
                         result.candidate.confirmationSteps,
                         result.gain,
                         result.meanWalkError * 100,
                         result.maxWalkError * 100,
                         result.restFalseSteps,
                         result.score,
                         counts))
        }

        guard let best = results.first, best.passes else {
            fail("no calibration candidate met <=3% mean walk error, <=5% per-walk error, and zero rest steps")
        }
        print(String(format: "\nselected filter=%d peak=%d sensitivity=%.2f confirmation=%d gain=%.4f",
                     best.candidate.filterLength,
                     best.candidate.peakWindow,
                     best.candidate.sensitivityG,
                     best.candidate.confirmationSteps,
                     best.gain))
    }

    private static func loadEvidence(
        directory: URL,
        windows: [CalibrationManifest.Window]
    ) throws -> [WindowEvidence] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "csv" }

        var frames = windows.map { _ in [(sampleAtMS: Int64, receivedAtMS: Int64, frame: Data)]() }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(whereSeparator: \.isNewline).dropFirst() {
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count >= 6,
                      let receivedAtMS = Int64(columns[1]),
                      let frame = data(hex: columns[5]),
                      let decoded = AtriaR10MotionDecoder.decode(frame: frame) else { continue }
                guard decoded.deviceTimestamp > 0 else { continue }
                let sampleAtMS = Int64(decoded.deviceTimestamp) * 1_000
                for index in windows.indices where sampleAtMS >= windows[index].startMS
                    && sampleAtMS < windows[index].endMS {
                    frames[index].append((sampleAtMS, receivedAtMS, frame))
                }
            }
        }

        return windows.indices.map { index in
            var magnitudes: [Double] = []
            var decodedFrames = 0
            var seenTimestamps = Set<UInt32>()
            var deviceTimestampsMS: [Int64] = []
            for row in frames[index].sorted(by: {
                if $0.sampleAtMS != $1.sampleAtMS { return $0.sampleAtMS < $1.sampleAtMS }
                return $0.receivedAtMS < $1.receivedAtMS
            }) {
                guard let decoded = AtriaR10MotionDecoder.decode(frame: row.frame),
                      decoded.deviceTimestamp > 0,
                      seenTimestamps.insert(decoded.deviceTimestamp).inserted else {
                    continue
                }
                decodedFrames += 1
                deviceTimestampsMS.append(Int64(decoded.deviceTimestamp) * 1_000)
                magnitudes.append(contentsOf: decoded.acceleration.map(\.magnitude))
            }
            return WindowEvidence(manifest: windows[index],
                                  decodedFrames: decodedFrames,
                                  deviceTimestampsMS: deviceTimestampsMS,
                                  magnitudes: magnitudes)
        }
    }

    private static func evaluate(candidate: Candidate,
                                 evidence: [WindowEvidence]) -> CandidateResult {
        let rawCounts = evidence.map {
            rawStepCount(magnitudes: $0.magnitudes, candidate: candidate)
        }
        let walkRatios = zip(evidence, rawCounts).compactMap { window, raw -> Double? in
            guard window.manifest.kind == .walk, raw > 0 else { return nil }
            return Double(window.manifest.expectedSteps) / Double(raw)
        }.sorted()
        let medianGain: Double
        if walkRatios.isEmpty {
            medianGain = 1
        } else if walkRatios.count.isMultiple(of: 2) {
            let upper = walkRatios.count / 2
            medianGain = (walkRatios[upper - 1] + walkRatios[upper]) / 2
        } else {
            medianGain = walkRatios[walkRatios.count / 2]
        }
        let gain = min(max(medianGain, 0.75), 1.50)
        let counts = rawCounts.map { Int((Double($0) * gain).rounded()) }
        let walkErrors = zip(evidence, counts).compactMap { window, count -> Double? in
            guard window.manifest.kind == .walk else { return nil }
            return abs(Double(count - window.manifest.expectedSteps))
                / Double(window.manifest.expectedSteps)
        }
        let restFalseSteps = zip(evidence, counts)
            .filter { $0.0.manifest.kind == .rest }
            .reduce(0) { $0 + max(0, $1.1) }
        return CandidateResult(candidate: candidate,
                               gain: gain,
                               counts: counts,
                               meanWalkError: walkErrors.reduce(0, +) / Double(max(1, walkErrors.count)),
                               maxWalkError: walkErrors.max() ?? 1,
                               restFalseSteps: restFalseSteps)
    }

    private static func rawStepCount(magnitudes: [Double],
                                     candidate: Candidate) -> Int {
        AtriaStrapPedometer.rawStepCount(
            magnitudes: magnitudes,
            filterLength: candidate.filterLength,
            peakWindow: candidate.peakWindow,
            sensitivityG: candidate.sensitivityG,
            confirmationSteps: candidate.confirmationSteps
        )
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

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}
