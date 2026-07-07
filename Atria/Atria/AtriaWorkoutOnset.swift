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
}
