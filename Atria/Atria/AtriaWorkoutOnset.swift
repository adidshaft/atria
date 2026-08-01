import Foundation

/// Finds where a workout's REAL effort begins, so the auto-detected start can
/// be trimmed off the getting-ready/walking-out lead-in (user-reported
/// 2026-07-07: workout detected 8:40 PM but started 9:06 PM).
///
/// Pure + deterministic. It never fabricates a boundary: it only reports the
/// timestamp of the first sample that begins a sustained run AT OR ABOVE the
/// elevated threshold (using the same continuity/micro-gap-reconnect logic as
/// workout detection). Callers apply strict guards and fail closed to the
/// untrimmed start when no honest onset exists.
enum AtriaWorkoutOnset {
    static func firstSustainedElevatedOnset(samples: [(t: Date, bpm: Int)],
                                            rest: Int,
                                            maxHR: Int,
                                            thresholdFraction: Double = 0.50,
                                            minimumOnsetSeconds: TimeInterval = 90,
                                            continuityGapLimit: TimeInterval = 15,
                                            microGapReseedCadence: TimeInterval = 3,
                                            microGapReseedJumpBPM: Int = 25) -> Date? {
        guard samples.count > 1 else { return nil }
        let reserve = max(0, maxHR - rest)
        guard reserve > 0 else { return nil }
        let threshold = rest + Int((Double(reserve) * min(max(thresholdFraction, 0), 1)).rounded())

        var boutStart: Date?
        var boutSeconds: TimeInterval = 0
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let dt = max(0, current.t.timeIntervalSince(previous.t))
            // A hard stream gap breaks the bout (matches sustainedEvidence).
            if dt > continuityGapLimit {
                boutStart = nil
                boutSeconds = 0
                continue
            }
            // A micro-gap reconnect paired with a big bpm jump is an unverified
            // blip — it cannot seed or extend an elevated bout.
            let microGapReconnect = dt > microGapReseedCadence
            let unverifiedBlip = microGapReconnect && abs(current.bpm - previous.bpm) >= microGapReseedJumpBPM
            let elevated = current.bpm >= threshold && !unverifiedBlip
            if elevated {
                if boutStart == nil {
                    boutStart = current.t
                    boutSeconds = 0
                } else {
                    boutSeconds += dt
                }
                if boutSeconds >= minimumOnsetSeconds, let start = boutStart {
                    return start
                }
            } else {
                boutStart = nil
                boutSeconds = 0
            }
        }
        return nil
    }

    /// Finds where a workout's REAL effort ends, so the auto-detected end can
    /// be trimmed off a long non-exertion tail (physical case 2026-07-31: a
    /// 21:20-22:35 lift followed by an ordinary mildly-elevated evening
    /// produced one 21:38->02:32 candidate that only closed at sleep-onset HR
    /// decay).
    ///
    /// Pure + deterministic, mirroring `firstSustainedElevatedOnset`: it only
    /// reports the timestamp of the LAST sample belonging to a sustained run
    /// AT OR ABOVE the elevated threshold (same continuity/micro-gap-reconnect
    /// rules). Callers add a short recovery tail, apply strict guards, and
    /// fail closed to the untrimmed end when no honest bout exists.
    static func lastSustainedElevatedBoutEnd(samples: [(t: Date, bpm: Int)],
                                             rest: Int,
                                             maxHR: Int,
                                             thresholdFraction: Double = 0.50,
                                             minimumBoutSeconds: TimeInterval = 90,
                                             continuityGapLimit: TimeInterval = 15,
                                             microGapReseedCadence: TimeInterval = 3,
                                             microGapReseedJumpBPM: Int = 25) -> Date? {
        guard samples.count > 1 else { return nil }
        let reserve = max(0, maxHR - rest)
        guard reserve > 0 else { return nil }
        let threshold = rest + Int((Double(reserve) * min(max(thresholdFraction, 0), 1)).rounded())

        var boutStart: Date?
        var boutSeconds: TimeInterval = 0
        var lastQualifiedBoutEnd: Date?
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            let dt = max(0, current.t.timeIntervalSince(previous.t))
            // A hard stream gap breaks the bout (matches sustainedEvidence).
            if dt > continuityGapLimit {
                boutStart = nil
                boutSeconds = 0
                continue
            }
            // A micro-gap reconnect paired with a big bpm jump is an unverified
            // blip — it cannot seed or extend an elevated bout.
            let microGapReconnect = dt > microGapReseedCadence
            let unverifiedBlip = microGapReconnect && abs(current.bpm - previous.bpm) >= microGapReseedJumpBPM
            let elevated = current.bpm >= threshold && !unverifiedBlip
            if elevated {
                if boutStart == nil {
                    boutStart = current.t
                    boutSeconds = 0
                } else {
                    boutSeconds += dt
                }
                if boutSeconds >= minimumBoutSeconds {
                    lastQualifiedBoutEnd = current.t
                }
            } else {
                boutStart = nil
                boutSeconds = 0
            }
        }
        return lastQualifiedBoutEnd
    }

    /// HR stats over a workout window's real samples. Pure so the
    /// honesty-critical averages (which must match a trimmed start/duration)
    /// are unit-testable. `windowSeconds` is the displayed span for coverage.
    static func windowStats(samples: [(t: Date, bpm: Int)],
                            windowSeconds: TimeInterval,
                            continuityGapLimit: TimeInterval = 15)
        -> (avgHR: Int, peakHR: Int, p95HR: Int, p99HR: Int,
            observedDuration: TimeInterval, streamCoveragePercent: Int, samples: Int)? {
        guard samples.count > 1 else { return nil }
        let bpms = samples.map(\.bpm)
        let sorted = bpms.sorted()
        func percentile(_ fraction: Double) -> Int {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return sorted[index]
        }
        var observed: TimeInterval = 0
        for index in 1..<samples.count {
            let dt = samples[index].t.timeIntervalSince(samples[index - 1].t)
            if dt <= continuityGapLimit { observed += dt }
        }
        let coverage = windowSeconds > 0
            ? min(100, max(0, Int((observed / windowSeconds * 100).rounded())))
            : 0
        return (bpms.reduce(0, +) / bpms.count,
                bpms.max() ?? 0,
                percentile(0.95),
                percentile(0.99),
                observed,
                coverage,
                samples.count)
    }
}
