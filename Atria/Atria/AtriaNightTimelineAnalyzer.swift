import Foundation

/// Deterministic night-timeline analysis from per-minute WHOOP 4 features.
///
/// Reference: tools/strap-mac/night_timeline.py (validated 2026-09-24 against
/// the owner's report: asleep ~23:40, up around 02:00, woke 08:01). Every
/// threshold self-calibrates per night, so no person-specific constants are
/// involved (population rule):
/// - "still" = motion ≤ 2.5 × the night's own resting-motion floor
///   (10th percentile of minute motion) with no firmware steps;
/// - "up" (walking) = ≥ 2 consecutive minutes with firmware steps totalling
///   ≥ 40 (rolling over produces isolated one-minute bursts);
/// - onset / final wake = first / last 20-minute window that is ≥ 80 % still.
/// Sleep stages (deep/REM) are deliberately NOT claimed. Lying still after
/// waking reads as rest, so final wake carries ~±10 min uncertainty.
enum AtriaNightTimelineAnalyzer {
    struct Minute: Equatable, Sendable {
        /// Minute start (wall clock).
        var start: Date
        /// Mean HR for the minute, if any sample.
        var heartRate: Double?
        /// Mean firmware motion-intensity (R10 float @42); `nil` when only
        /// history rows cover the minute (motion not decoded there).
        var motion: Double?
        /// Firmware step-counter increase inside the minute.
        var steps: Int
        /// Beat-to-beat intervals (ms) received in the minute.
        var rrIntervals: [Int]
        /// Strap reported no skin contact / zero HR while live.
        var offWrist: Bool
    }

    enum State: String, Equatable, Sendable {
        case still, restless, up, notWorn, unknownMotion
    }

    enum Kind: String, Equatable, Sendable {
        case settling, restless, up, notWorn, longestUndisturbed, awake
    }

    struct Episode: Equatable, Sendable {
        var kind: Kind
        var start: Date
        var end: Date
        var steps: Int?
        var meanHeartRate: Double?
        var rmssd: Double?
    }

    struct Result: Equatable, Sendable {
        var onset: Date?
        var wake: Date?
        var sleepingHeartRate: Double?
        var motionFloor: Double
        var episodes: [Episode]
        var states: [State]
    }

    static let stillMultiplier = 2.5
    static let walkingMinimumSteps = 40
    static let sustainedWindow = 20
    static let sustainedStillFraction = 0.8
    static let reportedRestlessMinimumMinutes = 5
    static let longestStretchMinimumMinutes = 30

    static func analyze(_ minutes: [Minute], lightsOff: Date? = nil) -> Result {
        let floor = motionFloor(minutes)
        let states = classify(minutes, floor: floor)
        let windows = sustainedWindowStarts(states)
        guard let first = windows.first, let last = windows.last else {
            return Result(onset: nil, wake: nil, sleepingHeartRate: nil, motionFloor: floor,
                          episodes: [], states: states)
        }
        let onset = first
        var wake = last + sustainedWindow - 1
        while wake + 1 < minutes.count, [.still, .unknownMotion].contains(states[wake + 1]) { wake += 1 }

        var episodes: [Episode] = []
        func add(_ kind: Kind, _ a: Int, _ b: Int, withStats: Bool = true) {
            let seg = minutes[a...b]
            let hrs = seg.compactMap(\.heartRate)
            episodes.append(Episode(
                kind: kind, start: minutes[a].start, end: minutes[b].start.addingTimeInterval(60),
                steps: withStats ? seg.reduce(0) { $0 + $1.steps } : nil,
                meanHeartRate: withStats && !hrs.isEmpty ? hrs.reduce(0, +) / Double(hrs.count) : nil,
                rmssd: nil))
        }

        if let lightsOff, let firstStart = minutes.first?.start, firstStart <= lightsOff,
           lightsOff < minutes[onset].start,
           let a = minutes.firstIndex(where: { $0.start >= lightsOff }), a < onset {
            add(.settling, a, onset - 1, withStats: false)
        }

        func disturbed(_ i: Int) -> Bool { [.restless, .up, .notWorn].contains(states[i]) }
        var interruptions: [(Int, Int)] = []
        var i = onset
        while i <= wake {
            guard disturbed(i) else { i += 1; continue }
            var j = i
            var k = i
            // Merge across short still gaps (≤ 2 minutes) when disturbance resumes.
            while k + 1 <= wake {
                let next = k + 1
                let lookEnd = min(next + 2, minutes.count - 1)
                let resumesSoon = next + 1 <= lookEnd && (next + 1...lookEnd).contains { disturbed($0) }
                if disturbed(next) || (states[next] == .still && resumesSoon) {
                    k = next
                    if disturbed(k) { j = k }
                } else {
                    break
                }
            }
            let range = i...j
            let ups = range.filter { states[$0] == .up }
            if !ups.isEmpty || range.count >= reportedRestlessMinimumMinutes {
                var parts: [(Int, Int, Kind)] = [(i, j, .restless)]
                if let u0 = ups.first, let u1 = ups.last {
                    parts = [(i, u0 - 1, .restless), (u0, u1, .up), (u1 + 1, j, .restless)]
                }
                for (a, b, kind) in parts where b >= a {
                    if kind == .restless, b - a + 1 < reportedRestlessMinimumMinutes { continue }
                    let allOff = (a...b).allSatisfy { states[$0] == .notWorn }
                    add(kind == .restless && allOff ? .notWorn : kind, a, b)
                }
                interruptions.append((i, j))
            }
            i = j + 1
        }

        // Longest undisturbed stretch between reported interruptions.
        var bounds = [onset - 1]
        for (a, b) in interruptions { bounds += [a, b] }
        bounds.append(wake + 1)
        var best: (length: Int, a: Int, b: Int)?
        var p = 0
        while p + 1 < bounds.count {
            let a = bounds[p] + 1, b = bounds[p + 1] - 1
            if b >= a, (best == nil || b - a + 1 > best!.length) { best = (b - a + 1, a, b) }
            p += 2
        }
        if let best, best.length >= longestStretchMinimumMinutes {
            add(.longestUndisturbed, best.a, best.b)
            let rr = minutes[best.a...best.b].flatMap(\.rrIntervals)
            episodes[episodes.count - 1].rmssd = rmssd(rr)
            episodes[episodes.count - 1].steps = nil
        }
        if wake + 1 < minutes.count { add(.awake, wake + 1, minutes.count - 1, withStats: false) }
        episodes.sort { $0.start < $1.start }

        let sleepingHR = (onset...wake)
            .filter { [.still, .unknownMotion].contains(states[$0]) }
            .compactMap { minutes[$0].heartRate }
            .sorted()
        return Result(
            onset: minutes[onset].start,
            wake: minutes[wake].start.addingTimeInterval(60),
            sleepingHeartRate: sleepingHR.isEmpty ? nil : sleepingHR[sleepingHR.count / 2],
            motionFloor: floor, episodes: episodes, states: states)
    }

    static func motionFloor(_ minutes: [Minute]) -> Double {
        let motions = minutes.compactMap(\.motion).sorted()
        guard !motions.isEmpty else { return 0.007 }
        return motions[max(0, motions.count / 10)]
    }

    static func classify(_ minutes: [Minute], floor: Double) -> [State] {
        var states: [State] = minutes.map { m in
            if m.offWrist { return .notWorn }
            guard let motion = m.motion else { return .unknownMotion }
            return motion <= stillMultiplier * floor && m.steps == 0 ? .still : .restless
        }
        var i = 0
        while i < minutes.count {
            guard minutes[i].steps > 0 else { i += 1; continue }
            var j = i
            while j + 1 < minutes.count, minutes[j + 1].steps > 0 { j += 1 }
            if j > i, minutes[i...j].reduce(0, { $0 + $1.steps }) >= walkingMinimumSteps {
                for k in i...j { states[k] = .up }
            }
            i = j + 1
        }
        return states
    }

    static func sustainedWindowStarts(_ states: [State]) -> [Int] {
        guard states.count >= sustainedWindow else { return [] }
        return (0...(states.count - sustainedWindow)).filter { i in
            let seg = states[i..<(i + sustainedWindow)]
            if seg.contains(.up) { return false }
            let score = seg.reduce(0.0) { $0 + ($1 == .still ? 1 : $1 == .unknownMotion ? 0.5 : 0) }
            return score / Double(sustainedWindow) >= sustainedStillFraction
        }
    }

    static func rmssd(_ intervals: [Int]) -> Double? {
        let rr = intervals.filter { (300...2_000).contains($0) }
        guard var last = rr.first else { return nil }
        var good = [last]
        for x in rr.dropFirst() where abs(Double(x - last)) <= 0.2 * Double(last) {
            good.append(x)
            last = x
        }
        guard good.count >= 20 else { return nil }
        let diffs = zip(good, good.dropFirst()).map { Double($1 - $0) }
        return (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
    }
}

/// Night interruptions worth asking the user about the next morning
/// (owner idea 2026-09-24): "You were up 01:43–02:28 — what was it?"
/// User answers turn a motion/HR guess into ground truth and enable personal
/// patterns. Labels are private by default; sensitive ones never leave the
/// device (no research sharing, no cloud coach) unless the user opts in.
enum AtriaNightInterruptionLabel: String, CaseIterable, Codable, Sendable {
    case bathroom, waterOrFood, childOrPet, workOrTask, couldNotSleep, noiseOrPartner, intimacy, other

    var title: String {
        switch self {
        case .bathroom: return "Bathroom"
        case .waterOrFood: return "Water or food"
        case .childOrPet: return "Child or pet"
        case .workOrTask: return "Work or a task"
        case .couldNotSleep: return "Couldn't sleep"
        case .noiseOrPartner: return "Noise or partner"
        case .intimacy: return "Intimacy"
        case .other: return "Something else"
        }
    }

    /// Sensitive labels are excluded from any off-device path by default.
    var isSensitive: Bool { self == .intimacy }
}

extension AtriaNightTimelineAnalyzer {
    static let askMinimumMinutes = 5

    /// Up (walking) episodes of any length, and restless episodes of at least
    /// `askMinimumMinutes`, inside the sleep window, oldest first.
    static func interruptionsToAsk(_ result: Result) -> [Episode] {
        guard let onset = result.onset, let wake = result.wake else { return [] }
        return result.episodes.filter { e in
            guard e.start >= onset, e.end <= wake else { return false }
            switch e.kind {
            case .up: return true
            case .restless: return e.end.timeIntervalSince(e.start) >= Double(askMinimumMinutes) * 60
            default: return false
            }
        }
    }
}
