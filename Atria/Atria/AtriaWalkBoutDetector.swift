import Foundation

/// Minute-level strap step log for walk detection (2026-09-30).
///
/// The live workout prompt only ran while the app was on screen, and it
/// needed raised heart rate before it looked at steps, so a pocketed walk at
/// 110–120 bpm was never offered (all five of the owner's recent workouts
/// were started by hand; the saved-window detector called the walks "not a
/// workout"). The R10 snapshot handler runs in the background too, so it
/// feeds this log; the prompt reads it when the app is next opened.
///
/// Counts are stored as per-minute deltas of the strap's session step
/// count. A count that goes backwards (new session, reconnect carry) starts a
/// new baseline and adds nothing, so a reset can never fabricate steps.
final class AtriaStrapStepMinuteLog: @unchecked Sendable {
    static let shared = AtriaStrapStepMinuteLog()
    static let retention: TimeInterval = 4 * 60 * 60

    struct Minute: Equatable, Sendable {
        let start: Date
        var steps: Int
    }

    private let lock = NSLock()
    private var minutes: [Minute] = []
    private var lastCount: Int?
    private var lastCountAt: Date?

    func record(sessionSteps: Int, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        defer {
            lastCount = sessionSteps
            lastCountAt = date
        }
        guard let lastCount, let lastCountAt, date >= lastCountAt else { return }
        // A long silence (link down, R10 paused) is not evidence of when the
        // steps in between happened; start a fresh baseline instead.
        guard date.timeIntervalSince(lastCountAt) <= 120 else { return }
        let delta = sessionSteps - lastCount
        guard delta > 0 else { return }
        let minuteStart = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
        if let last = minutes.last, last.start == minuteStart {
            minutes[minutes.count - 1].steps += delta
        } else if minutes.last.map({ $0.start < minuteStart }) ?? true {
            minutes.append(Minute(start: minuteStart, steps: delta))
        }
        let cutoff = date.addingTimeInterval(-Self.retention)
        if let first = minutes.first, first.start < cutoff {
            minutes.removeAll { $0.start < cutoff }
        }
    }

    func snapshot() -> [Minute] {
        lock.lock()
        defer { lock.unlock() }
        return minutes
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        minutes.removeAll()
        lastCount = nil
        lastCountAt = nil
    }
}

/// Sustained walking from strap step cadence alone. Normal walking is
/// 90–120 steps/min; 60 leaves room for a slow stroll and short waits while
/// excluding desk and household shuffling (the prompt gate's desk case read
/// under 5 steps/min).
enum AtriaWalkBoutDetector {
    static let minimumStepsPerMinute = 60
    static let minimumBoutMinutes = 8
    /// One slow minute (a crossing, a door) does not end a walk.
    static let allowedSlowMinutes = 1
    /// A walk counts as finished once no walking minute has been seen for this long.
    static let completionQuietMinutes = 3
    static let maximumAge: TimeInterval = 3 * 60 * 60

    struct Bout: Equatable, Sendable {
        let start: Date
        let end: Date
        let steps: Int
        let ongoing: Bool

        var durationSeconds: Int { Int(end.timeIntervalSince(start)) }
        var stepsPerMinute: Double { Double(steps) / max(1, end.timeIntervalSince(start) / 60) }
    }

    /// The newest qualifying walk within `maximumAge`, ongoing or finished.
    static func latestBout(minutes: [AtriaStrapStepMinuteLog.Minute], now: Date) -> Bout? {
        let recent = minutes.filter { now.timeIntervalSince($0.start) <= maximumAge }
        guard !recent.isEmpty else { return nil }
        var steps: [Date: Int] = [:]
        for minute in recent { steps[minute.start] = minute.steps }
        let first = recent[0].start
        let lastMinute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60)
        var bouts: [Bout] = []
        var runStart: Date?
        var runEnd: Date?
        var runSteps = 0
        var slow = 0
        var slowSteps = 0
        var cursor = first
        func close() {
            if let runStart, let runEnd {
                let length = Int(runEnd.timeIntervalSince(runStart) / 60)
                if length >= minimumBoutMinutes {
                    let quiet = Int(lastMinute.timeIntervalSince(runEnd) / 60)
                    bouts.append(Bout(start: runStart,
                                      end: runEnd,
                                      steps: runSteps,
                                      ongoing: quiet < completionQuietMinutes))
                }
            }
            runStart = nil
            runEnd = nil
            runSteps = 0
            slow = 0
            slowSteps = 0
        }
        while cursor <= lastMinute {
            let count = steps[cursor] ?? 0
            if count >= minimumStepsPerMinute {
                if runStart == nil { runStart = cursor }
                runEnd = cursor.addingTimeInterval(60)
                runSteps += count + slowSteps
                slow = 0
                slowSteps = 0
            } else if runStart != nil {
                slow += 1
                slowSteps += count
                if slow > allowedSlowMinutes { close() }
            }
            cursor = cursor.addingTimeInterval(60)
        }
        close()
        return bouts.last
    }
}
