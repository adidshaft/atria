import Foundation

private struct CalibrationManifest: Decodable {
    struct Window: Decodable {
        enum Kind: String, Decodable {
            case walk
            case run
            case rest
            case negative

            var expectsSteps: Bool {
                self == .walk || self == .run
            }
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
    let rotationMagnitudes: [Double]

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

private struct GyroCandidate {
    let rotationLevelGate: Double
    let prominenceGate: Double
    let turnWindowDiscount: Double
}

private struct GyroCandidateResult {
    let candidate: GyroCandidate
    let counts: [Double]
    let meanWalkError: Double
    let maxWalkError: Double
    let restFalseSteps: Double

    var score: Double {
        meanWalkError + maxWalkError * 0.75 + restFalseSteps * 0.25
    }

    var passes: Bool {
        restFalseSteps == 0 && meanWalkError <= 0.03 && maxWalkError <= 0.05
    }
}

private struct HoldoutWindowResult {
    let evidence: WindowEvidence
    let rawSteps: Int
    let steps: Int
    let error: Double?

    var passes: Bool {
        if evidence.manifest.kind.expectsSteps {
            return (error ?? .infinity) <= 0.05
        }
        return steps == 0
    }
}

@main
enum FitStepCalibration {
    private static let usage = "usage: fit_step_calibration <csv-directory> <manifest.json> [--holdout-manifest <holdout.json>]"

    static func main() throws {
        let arguments = parseArguments(CommandLine.arguments)

        let archiveDirectory = arguments.archiveDirectory
        let manifestURL = arguments.calibrationManifestURL
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
        validateWindowShapes(manifest.windows, requireLongRest: true)

        let evidence = try loadAndPrintEvidence(directory: archiveDirectory,
                                                windows: manifest.windows,
                                                heading: "evidence")

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

        // Second detector family: gyro-cadence (rotation-rate magnitude
        // oscillates at the true step rate; see
        // AtriaGyroCadenceResearchPedometer). Swept under identical gates so
        // one guided session can arbitrate both families.
        var gyroResults: [GyroCandidateResult] = []
        for levelGate in [25.0, 30.0, 35.0, 40.0, 45.0] {
            for prominence in [1.4, 1.6, 1.8, 2.0, 2.2] {
                for discountTwentieths in 8...20 {
                    let candidate = GyroCandidate(
                        rotationLevelGate: levelGate,
                        prominenceGate: prominence,
                        turnWindowDiscount: Double(discountTwentieths) / 20
                    )
                    gyroResults.append(evaluateGyro(candidate: candidate,
                                                    evidence: evidence))
                }
            }
        }
        gyroResults.sort {
            if $0.passes != $1.passes { return $0.passes && !$1.passes }
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.restFalseSteps != $1.restFalseSteps { return $0.restFalseSteps < $1.restFalseSteps }
            return $0.maxWalkError < $1.maxWalkError
        }
        print("\nranked_gyro_candidates")
        for (rank, result) in gyroResults.prefix(10).enumerated() {
            let counts = zip(evidence, result.counts)
                .map { String(format: "%@=%.1f", $0.manifest.label, $1) }
                .joined(separator: ",")
            print(String(format: "%02d pass=%d level=%.0f prominence=%.1f turn_discount=%.2f mean_walk_error=%.2f%% max_walk_error=%.2f%% rest_false_steps=%.1f score=%.4f counts=%@",
                         rank + 1,
                         result.passes ? 1 : 0,
                         result.candidate.rotationLevelGate,
                         result.candidate.prominenceGate,
                         result.candidate.turnWindowDiscount,
                         result.meanWalkError * 100,
                         result.maxWalkError * 100,
                         result.restFalseSteps,
                         result.score,
                         counts))
        }

        let accelBest = results.first.flatMap { $0.passes ? $0 : nil }
        let gyroBest = gyroResults.first.flatMap { $0.passes ? $0 : nil }
        if let best = accelBest {
            print(String(format: "\nselected filter=%d peak=%d sensitivity=%.2f confirmation=%d gain=%.4f",
                         best.candidate.filterLength,
                         best.candidate.peakWindow,
                         best.candidate.sensitivityG,
                         best.candidate.confirmationSteps,
                         best.gain))
        }
        if let best = gyroBest {
            print(String(format: "%@selected_gyro level=%.0f prominence=%.1f turn_discount=%.2f",
                         accelBest == nil ? "\n" : "",
                         best.candidate.rotationLevelGate,
                         best.candidate.prominenceGate,
                         best.candidate.turnWindowDiscount))
        }
        guard accelBest != nil || gyroBest != nil else {
            fail("no calibration candidate in either family met <=3% mean walk error, <=5% per-walk error, and zero rest steps")
        }

        // Holdout evidence is deliberately decoded and scored only after the
        // training candidates and gains are frozen. It therefore cannot
        // influence parameter ranking or silently re-fit anything. Every
        // family that passed training must also pass its holdouts.
        if let holdoutManifestURL = arguments.holdoutManifestURL {
            let holdoutManifest = try JSONDecoder().decode(
                CalibrationManifest.self,
                from: Data(contentsOf: holdoutManifestURL)
            )
            validateHoldoutManifest(holdoutManifest, calibration: manifest)
            let holdoutEvidence = try loadAndPrintEvidence(
                directory: archiveDirectory,
                windows: holdoutManifest.windows,
                heading: "holdout_evidence"
            )
            if let best = accelBest {
                validateHoldouts(candidate: best.candidate,
                                 gain: best.gain,
                                 evidence: holdoutEvidence)
            }
            if let best = gyroBest {
                validateGyroHoldouts(candidate: best.candidate,
                                     evidence: holdoutEvidence)
            }
        } else {
            print("holdout_validation=not_provided")
        }
    }

    private struct ParsedArguments {
        let archiveDirectory: URL
        let calibrationManifestURL: URL
        let holdoutManifestURL: URL?
    }

    private static func parseArguments(_ commandLine: [String]) -> ParsedArguments {
        guard commandLine.count == 3 || commandLine.count == 5 else {
            fail(usage)
        }
        let holdoutManifestURL: URL?
        if commandLine.count == 5 {
            guard commandLine[3] == "--holdout-manifest" else {
                fail("unknown option: \(commandLine[3])\n\(usage)")
            }
            holdoutManifestURL = URL(fileURLWithPath: commandLine[4])
        } else {
            holdoutManifestURL = nil
        }
        return ParsedArguments(
            archiveDirectory: URL(fileURLWithPath: commandLine[1], isDirectory: true),
            calibrationManifestURL: URL(fileURLWithPath: commandLine[2]),
            holdoutManifestURL: holdoutManifestURL
        )
    }

    private static func validateHoldoutManifest(
        _ manifest: CalibrationManifest,
        calibration: CalibrationManifest
    ) {
        guard !manifest.windows.isEmpty else {
            fail("holdout manifest must contain at least one window")
        }
        guard Set(manifest.windows.map(\.label)).count == manifest.windows.count else {
            fail("holdout window labels must be unique")
        }
        validateWindowShapes(manifest.windows, requireLongRest: false)
        guard manifest.windows.contains(where: { $0.kind.expectsSteps }) else {
            fail("holdout manifest requires at least one counted walk or run")
        }
        guard manifest.windows.contains(where: { !$0.kind.expectsSteps }) else {
            fail("holdout manifest requires at least one zero-step negative")
        }
        for holdout in manifest.windows {
            for fitted in calibration.windows where overlaps(holdout, fitted) {
                fail("holdout overlaps calibration evidence: \(holdout.label), \(fitted.label)")
            }
        }
    }

    private static func validateWindowShapes(
        _ windows: [CalibrationManifest.Window],
        requireLongRest: Bool
    ) {
        for window in windows {
            guard !window.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  window.startMS < window.endMS,
                  window.expectedSteps >= 0,
                  (window.kind.expectsSteps ? window.expectedSteps > 0 : window.expectedSteps == 0),
                  !requireLongRest || window.kind != .rest || window.endMS - window.startMS >= 60_000 else {
                fail("invalid window: \(window.label)")
            }
        }
        for (previous, next) in zip(windows, windows.dropFirst()) {
            guard previous.endMS <= next.startMS else {
                fail("windows must be chronological and non-overlapping: \(previous.label), \(next.label)")
            }
        }
        for (index, window) in windows.enumerated() {
            for other in windows.dropFirst(index + 1) where overlaps(window, other) {
                fail("overlapping windows: \(window.label) and \(other.label)")
            }
        }
    }

    private static func overlaps(
        _ lhs: CalibrationManifest.Window,
        _ rhs: CalibrationManifest.Window
    ) -> Bool {
        lhs.startMS < rhs.endMS && rhs.startMS < lhs.endMS
    }

    private static func loadAndPrintEvidence(
        directory: URL,
        windows: [CalibrationManifest.Window],
        heading: String
    ) throws -> [WindowEvidence] {
        let evidence = try loadEvidence(directory: directory, windows: windows)
        var evidenceIsComplete = true
        print("\n\(heading)")
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
        return evidence
    }

    private static func validateHoldouts(
        candidate: Candidate,
        gain: Double,
        evidence: [WindowEvidence]
    ) {
        let results = evidence.map { window -> HoldoutWindowResult in
            let raw = rawStepCount(magnitudes: window.magnitudes, candidate: candidate)
            let steps = Int((Double(raw) * gain).rounded())
            let error = window.manifest.kind.expectsSteps
                ? abs(Double(steps - window.manifest.expectedSteps))
                    / Double(window.manifest.expectedSteps)
                : nil
            return HoldoutWindowResult(evidence: window,
                                       rawSteps: raw,
                                       steps: steps,
                                       error: error)
        }
        print("\nholdout_results")
        for result in results {
            if let error = result.error {
                print(String(format: "%@ kind=%@ expected=%d raw=%d steps=%d error=%.2f%% pass=%d",
                             result.evidence.manifest.label,
                             result.evidence.manifest.kind.rawValue,
                             result.evidence.manifest.expectedSteps,
                             result.rawSteps,
                             result.steps,
                             error * 100,
                             result.passes ? 1 : 0))
            } else {
                print(String(format: "%@ kind=%@ expected=0 raw=%d steps=%d false_steps=%d pass=%d",
                             result.evidence.manifest.label,
                             result.evidence.manifest.kind.rawValue,
                             result.rawSteps,
                             result.steps,
                             result.steps,
                             result.passes ? 1 : 0))
            }
        }
        let failed = results.filter { !$0.passes }
        print("holdout_summary windows=\(results.count) passed=\(results.count - failed.count) failed=\(failed.count) pass=\(failed.isEmpty ? 1 : 0)")
        guard failed.isEmpty else {
            fail("selected candidate failed independent holdout validation")
        }
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
                for index in windows.indices where sampleAtMS >= windows[index].startMS
                    && sampleAtMS < windows[index].endMS {
                    frames[index].append((sampleAtMS, receivedAtMS, frame))
                }
            }
        }

        return windows.indices.map { index in
            var magnitudes: [Double] = []
            var rotationMagnitudes: [Double] = []
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
                rotationMagnitudes.append(contentsOf: decoded.rotationRate.map(\.magnitude))
            }
            return WindowEvidence(manifest: windows[index],
                                  decodedFrames: decodedFrames,
                                  deviceTimestampsMS: deviceTimestampsMS,
                                  magnitudes: magnitudes,
                                  rotationMagnitudes: rotationMagnitudes)
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

    private static func evaluateGyro(candidate: GyroCandidate,
                                     evidence: [WindowEvidence]) -> GyroCandidateResult {
        // Windows entering the fitter are contiguity-verified upstream, so
        // each rotation series is a single physical segment.
        let counts = evidence.map {
            AtriaGyroCadenceResearchPedometer.steps(
                contiguousRotationMagnitudes: $0.rotationMagnitudes,
                rotationLevelGate: candidate.rotationLevelGate,
                prominenceGate: candidate.prominenceGate,
                turnWindowDiscount: candidate.turnWindowDiscount
            )
        }
        let walkErrors = zip(evidence, counts).compactMap { window, count -> Double? in
            guard window.manifest.kind == .walk else { return nil }
            return abs(count - Double(window.manifest.expectedSteps))
                / Double(window.manifest.expectedSteps)
        }
        let restFalseSteps = zip(evidence, counts)
            .filter { $0.0.manifest.kind == .rest }
            .reduce(0.0) { $0 + max(0, $1.1) }
        return GyroCandidateResult(candidate: candidate,
                                   counts: counts,
                                   meanWalkError: walkErrors.reduce(0, +) / Double(max(1, walkErrors.count)),
                                   maxWalkError: walkErrors.max() ?? 1,
                                   restFalseSteps: restFalseSteps)
    }

    private static func validateGyroHoldouts(candidate: GyroCandidate,
                                             evidence: [WindowEvidence]) {
        print("\ngyro_holdout_results")
        var failures = 0
        for window in evidence {
            let steps = AtriaGyroCadenceResearchPedometer.steps(
                contiguousRotationMagnitudes: window.rotationMagnitudes,
                rotationLevelGate: candidate.rotationLevelGate,
                prominenceGate: candidate.prominenceGate,
                turnWindowDiscount: candidate.turnWindowDiscount
            )
            let passes: Bool
            if window.manifest.kind.expectsSteps {
                let error = abs(steps - Double(window.manifest.expectedSteps))
                    / Double(window.manifest.expectedSteps)
                passes = error <= 0.05
                print(String(format: "%@ kind=%@ expected=%d steps=%.1f error=%.2f%% pass=%d",
                             window.manifest.label,
                             window.manifest.kind.rawValue,
                             window.manifest.expectedSteps,
                             steps,
                             error * 100,
                             passes ? 1 : 0))
            } else {
                passes = steps == 0
                print(String(format: "%@ kind=%@ expected=0 steps=%.1f false_steps=%.1f pass=%d",
                             window.manifest.label,
                             window.manifest.kind.rawValue,
                             steps,
                             steps,
                             passes ? 1 : 0))
            }
            if !passes { failures += 1 }
        }
        print("gyro_holdout_summary windows=\(evidence.count) passed=\(evidence.count - failures) failed=\(failures) pass=\(failures == 0 ? 1 : 0)")
        guard failures == 0 else {
            fail("selected gyro candidate failed independent holdout validation")
        }
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

    /// Calibration archives are intentionally durable and can grow well past
    /// the size of a single useful window. Process them incrementally so a
    /// valid six-stage fit cannot fail merely because unrelated retained CSV
    /// rows exhaust the replay process's memory.
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
