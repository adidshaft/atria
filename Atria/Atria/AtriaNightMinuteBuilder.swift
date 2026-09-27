import Foundation

/// Assembles `AtriaNightTimelineAnalyzer.Minute`s for one sleep window from
/// data the app already stores on the phone. Pure: the loader below does the
/// (read-only, off-main) store reads and hands the samples in.
///
/// Sources, per minute:
/// - heart rate: mean of accepted bpm samples (historical archive, falling
///   back to saved-session points when the exact archive read is incomplete);
/// - motion: mean of the WHOOP 4 v24 history motion scalar (float at payload
///   bytes 32–35). On the owner's shards it rests at ~0.007 asleep and reads
///   0.1–0.6 when moving, the same shape as the live R10 float the analyzer
///   was built on. The analyzer only uses it RELATIVE to the night's own
///   10th percentile, so its absolute scale never matters;
/// - movement counter: v24 motion ticks (bytes 88–89) stand in for the live
///   firmware step counter. Both are silent at rest and advance during gait.
///   The analyzer only uses them to tell a sustained walk (≥ 2 minutes,
///   ≥ 40 total) from a roll-over burst. They are never shown as steps
///   (one tick is not always one step — see WHOOP4_PROTOCOL_FINDINGS);
/// - RR: beat intervals from saved live sessions, only with a known source.
///
/// Honesty rules:
/// - a minute with no sample stays nil (heart rate / motion) — nothing is
///   interpolated or carried forward;
/// - `offWrist` is never set: the app keeps no per-minute contact record, only
///   aggregate counters, so "not worn" is not claimed from production data;
/// - coverage is reported separately so the UI can say "no motion data"
///   instead of drawing a timeline it cannot back.
enum AtriaNightMinuteBuilder {
    struct HeartRateSample: Equatable, Sendable {
        let t: Date
        let bpm: Int
    }

    struct MotionSample: Equatable, Sendable {
        let timestamp: TimeInterval
        let tick: Int
        let scalar: Double?
    }

    struct RRSample: Equatable, Sendable {
        let t: Date
        let ms: Int
    }

    struct Coverage: Equatable, Codable, Sendable {
        var totalMinutes: Int
        var heartRateMinutes: Int
        /// Minutes with a motion-intensity value (what the analyzer needs).
        var motionMinutes: Int

        var motionFraction: Double {
            totalMinutes > 0 ? Double(motionMinutes) / Double(totalMinutes) : 0
        }

        var heartRateFraction: Double {
            totalMinutes > 0 ? Double(heartRateMinutes) / Double(totalMinutes) : 0
        }

        /// No motion anywhere in the window: the analyzer cannot place sleep.
        var hasNoMotion: Bool { motionMinutes == 0 }

        /// Some motion, but under half the window: say so under the chart.
        var motionIsPartial: Bool { !hasNoMotion && motionFraction < 0.5 }
    }

    struct Build: Equatable, Sendable {
        let minutes: [AtriaNightTimelineAnalyzer.Minute]
        let coverage: Coverage
    }

    /// Plausible accepted heart rate for any adult at rest or walking.
    static let plausibleHeartRate = 25...250
    /// Row pairs further apart than this are a gap, not one motion interval
    /// (same bound as the daytime quiescence adapter).
    static let maximumRowGapSeconds: TimeInterval = 90
    /// A counter jump faster than this per second is a wrap/replay artefact,
    /// not movement (same bound as the daytime quiescence adapter).
    static let maximumTicksPerSecond: Double = 12
    /// A night window never needs more than this many minutes.
    static let maximumMinutes = 18 * 60

    static func build(window: DateInterval,
                      heartRate: [HeartRateSample],
                      motion: [MotionSample],
                      rr: [RRSample]) -> Build {
        let firstBucket = Int((window.start.timeIntervalSince1970 / 60).rounded(.down))
        let lastBucketExclusive = Int((window.end.timeIntervalSince1970 / 60).rounded(.up))
        let count = max(0, min(maximumMinutes, lastBucketExclusive - firstBucket))
        guard count > 0 else {
            return Build(minutes: [], coverage: Coverage(totalMinutes: 0, heartRateMinutes: 0, motionMinutes: 0))
        }
        func index(_ seconds: TimeInterval) -> Int? {
            let i = Int((seconds / 60).rounded(.down)) - firstBucket
            return (0..<count).contains(i) ? i : nil
        }

        var hrSum = [Double](repeating: 0, count: count)
        var hrN = [Int](repeating: 0, count: count)
        for sample in heartRate where plausibleHeartRate.contains(sample.bpm) {
            guard let i = index(sample.t.timeIntervalSince1970) else { continue }
            hrSum[i] += Double(sample.bpm)
            hrN[i] += 1
        }

        var scalarSum = [Double](repeating: 0, count: count)
        var scalarN = [Int](repeating: 0, count: count)
        var ticks = [Int](repeating: 0, count: count)
        let ordered = motion.sorted { $0.timestamp < $1.timestamp }
        for sample in ordered {
            guard let scalar = sample.scalar, scalar.isFinite, scalar >= 0,
                  let i = index(sample.timestamp) else { continue }
            scalarSum[i] += scalar
            scalarN[i] += 1
        }
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            let dt = after.timestamp - before.timestamp
            guard dt > 0, dt <= maximumRowGapSeconds,
                  let i = index(before.timestamp) else { continue }
            let delta = after.tick >= before.tick
                ? after.tick - before.tick
                : after.tick + 65_536 - before.tick
            if delta > 0, Double(delta) <= max(maximumTicksPerSecond, dt * maximumTicksPerSecond) {
                ticks[i] += delta
            }
        }

        var beats = [[Int]](repeating: [], count: count)
        for sample in rr {
            guard let i = index(sample.t.timeIntervalSince1970) else { continue }
            beats[i].append(sample.ms)
        }

        var minutes: [AtriaNightTimelineAnalyzer.Minute] = []
        minutes.reserveCapacity(count)
        var hrMinutes = 0
        var motionMinutes = 0
        for i in 0..<count {
            let hr: Double? = hrN[i] > 0 ? hrSum[i] / Double(hrN[i]) : nil
            let intensity: Double? = scalarN[i] > 0 ? scalarSum[i] / Double(scalarN[i]) : nil
            if hr != nil { hrMinutes += 1 }
            if intensity != nil { motionMinutes += 1 }
            minutes.append(.init(start: Date(timeIntervalSince1970: Double(firstBucket + i) * 60),
                                 heartRate: hr,
                                 motion: intensity,
                                 steps: ticks[i],
                                 rrIntervals: beats[i],
                                 offWrist: false))
        }
        return Build(minutes: minutes,
                     coverage: Coverage(totalMinutes: count,
                                        heartRateMinutes: hrMinutes,
                                        motionMinutes: motionMinutes))
    }

    /// The analysed window around a stored sleep: 30 minutes either side so
    /// the analyzer can find its own onset and wake, capped so a mis-edited
    /// all-day record cannot turn into an unbounded read.
    static let windowPadding: TimeInterval = 30 * 60

    static func window(sleepStart: Date, sleepEnd: Date) -> DateInterval? {
        guard sleepEnd > sleepStart else { return nil }
        let start = sleepStart.addingTimeInterval(-windowPadding)
        let end = min(sleepEnd.addingTimeInterval(windowPadding),
                      start.addingTimeInterval(Double(maximumMinutes) * 60))
        return DateInterval(start: start, end: end)
    }
}
