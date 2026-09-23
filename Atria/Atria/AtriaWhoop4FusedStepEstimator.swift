import Foundation

/// Fused WHOOP 4 step estimator over contiguous native R10 frames.
///
/// Reference implementation: tools/strap-mac/fused_steps.py (2026-09-23). Gates are
/// physical and wrist-agnostic (no owner-specific constants):
/// - a 10-frame window (~9.6 s, hop 5) is WALKING when the firmware gravity
///   vector's orientation wobble (per-axis SD, combined) is ≤ 0.18 g AND the
///   accel-magnitude autocorrelation peak over step-period lags 0.35–1.2 s is
///   ≥ 0.25 (rhythmic body bounce). Gesturing fails the wobble gate; typing and
///   hand-to-mouth fail periodicity.
/// - Frames covered by any walking window form bouts; bouts never cross a
///   frame-counter or device-time discontinuity.
/// - Per bout: the gyro-cadence count (`AtriaGyroCadenceResearchPedometer`) when
///   it is ≥ 0.7 × the firmware step-counter delta; otherwise the firmware delta
///   (arm not swinging: carrying a bag, holding a phone).
///
/// Validation is n = 1 (one subject, one session): whole 30-min stream
/// 722.5 vs 750 labelled steps (−3.7 %), 0 false steps on typing, hand-to-mouth,
/// and hand-talk on both wrists. Must be re-validated across people before any
/// product claim.
enum AtriaWhoop4FusedStepEstimator {
    struct Frame: Sendable {
        let record: AtriaWhoop4R10Record
        let motion: AtriaR10MotionFrame
    }

    enum Source: String, Sendable {
        case gyroCadence
        case firmwareCounter
    }

    struct Bout: Equatable, Sendable {
        let firstFrameCounter: UInt16
        let lastFrameCounter: UInt16
        let frameCount: Int
        let gyroSteps: Double
        let firmwareSteps: Int
        let steps: Double
        let source: Source
    }

    struct Result: Equatable, Sendable {
        let steps: Double
        let bouts: [Bout]
    }

    static let windowFrames = 10
    static let hopFrames = 5
    static let minimumWindowFrames = 5
    static let maximumGravityWobbleG = 0.18
    static let minimumPeriodicity = 0.25
    static let periodicityLagSeconds = 0.35...1.2
    static let gyroToFirmwareMinimumRatio = 0.7

    static func estimate(frames: [Frame]) -> Result {
        var total = 0.0
        var bouts: [Bout] = []
        for span in contiguousSpans(frames) {
            var walking = [Bool](repeating: false, count: span.count)
            var start = 0
            let lastStart = max(1, span.count - windowFrames + 1)
            while start < lastStart {
                let end = min(start + windowFrames, span.count)
                let window = Array(span[start..<end])
                if window.count >= minimumWindowFrames,
                   gravityWobble(window) <= maximumGravityWobbleG,
                   periodicity(accelerationMagnitudes(window)) >= minimumPeriodicity {
                    for j in start..<end { walking[j] = true }
                }
                start += hopFrames
            }
            var run: [Frame] = []
            for (frame, isWalking) in zip(span, walking) {
                if isWalking {
                    run.append(frame)
                } else if !run.isEmpty {
                    let bout = score(run)
                    total += bout.steps
                    bouts.append(bout)
                    run.removeAll()
                }
            }
            if !run.isEmpty {
                let bout = score(run)
                total += bout.steps
                bouts.append(bout)
            }
        }
        return Result(steps: total, bouts: bouts)
    }

    static func contiguousSpans(_ frames: [Frame]) -> [[Frame]] {
        var spans: [[Frame]] = []
        var current: [Frame] = []
        for frame in frames {
            if let previous = current.last {
                let counterStep = frame.record.frameCounter &- previous.record.frameCounter
                let secondStep = Int64(frame.record.deviceSecond) - Int64(previous.record.deviceSecond)
                if counterStep != 1 || !(0...1).contains(secondStep) {
                    spans.append(current)
                    current = []
                }
            }
            current.append(frame)
        }
        if !current.isEmpty { spans.append(current) }
        return spans
    }

    static func gravityWobble(_ window: [Frame]) -> Double {
        let n = Double(window.count)
        let xs = window.map(\.record.calibratedGravity.x)
        let ys = window.map(\.record.calibratedGravity.y)
        let zs = window.map(\.record.calibratedGravity.z)
        func variance(_ v: [Double]) -> Double {
            let mean = v.reduce(0, +) / n
            return v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        }
        return (variance(xs) + variance(ys) + variance(zs)).squareRoot()
    }

    static func accelerationMagnitudes(_ window: [Frame]) -> [Double] {
        window.flatMap { $0.motion.acceleration.map(\.magnitude) }
    }

    /// Peak normalized autocorrelation over step-period lags (0 = no rhythm).
    static func periodicity(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let x = samples.map { $0 - mean }
        let variance = x.reduce(0) { $0 + $1 * $1 } / Double(x.count)
        guard variance > 1e-6 else { return 0 }
        let rate = AtriaWhoop4R10Record.imuSampleRateHz
        let lowLag = Int(periodicityLagSeconds.lowerBound * rate)
        let highLag = Int(periodicityLagSeconds.upperBound * rate)
        var best = 0.0
        var lag = lowLag
        while lag < highLag, lag < x.count {
            let n = x.count - lag
            var sum = 0.0
            for i in 0..<n { sum += x[i] * x[i + lag] }
            best = max(best, sum / Double(n) / variance)
            lag += 1
        }
        return best
    }

    private static func score(_ run: [Frame]) -> Bout {
        let rotation = run.flatMap { $0.motion.rotationRate.map(\.magnitude) }
        let gyro = AtriaGyroCadenceResearchPedometer.steps(contiguousRotationMagnitudes: rotation)
        let firmware = AtriaWhoop4R10Record.firmwareStepDelta(
            from: run[0].record.firmwareStepCounter,
            to: run[run.count - 1].record.firmwareStepCounter
        )
        let useGyro = gyro >= gyroToFirmwareMinimumRatio * Double(firmware)
        return Bout(
            firstFrameCounter: run[0].record.frameCounter,
            lastFrameCounter: run[run.count - 1].record.frameCounter,
            frameCount: run.count,
            gyroSteps: gyro,
            firmwareSteps: firmware,
            steps: useGyro ? gyro : Double(firmware),
            source: useGyro ? .gyroCadence : .firmwareCounter
        )
    }
}
