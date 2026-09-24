import XCTest
@testable import Atria

/// Golden night (owner, 2026-09-23/24; fixture untracked: private biometrics)
/// plus population invariants that must hold for any person/strap.
final class AtriaNightTimelineAnalyzerTests: XCTestCase {
    typealias A = AtriaNightTimelineAnalyzer

    private struct Fixture: Decodable {
        struct M: Decodable {
            let t: Double
            let hr: Double?
            let motion: Double?
            let steps: Int
            let rr: [Int]
            let off_wrist: Bool
        }
        struct Ref: Decodable {
            struct E: Decodable { let kind: String; let start: Double; let end: Double }
            let onset: Double
            let wake: Double
            let episodes: [E]
        }
        let lights_off: Double
        let minutes: [M]
        let reference: Ref
    }

    private func golden() throws -> (minutes: [A.Minute], fixture: Fixture) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Atria/AtriaTests/Fixtures/whoop4-night-2026-09-23-minutes.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("private golden night fixture not present")
        }
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let minutes = f.minutes.map {
            A.Minute(start: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr, motion: $0.motion,
                     steps: $0.steps, rrIntervals: $0.rr, offWrist: $0.off_wrist)
        }
        return (minutes, f)
    }

    private func ist(_ hhmm: String, nextDay: Bool) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = nextDay ? 24 : 23
        let parts = hhmm.split(separator: ":").map { Int($0)! }
        c.hour = parts[0]; c.minute = parts[1]
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testGoldenNightMatchesReferenceAndGroundTruth() throws {
        let (minutes, f) = try golden()
        let r = A.analyze(minutes, lightsOff: Date(timeIntervalSince1970: f.lights_off))
        // Parity with the Python reference.
        XCTAssertEqual(r.onset?.timeIntervalSince1970, f.reference.onset)
        XCTAssertEqual(r.wake?.timeIntervalSince1970, f.reference.wake)
        XCTAssertEqual(r.episodes.map(\.kind.rawValue),
                       f.reference.episodes.map { $0.kind == "longest_undisturbed" ? "longestUndisturbed" : $0.kind })
        // Ground truth (owner): asleep ~23:40, up around 02:00, woke 08:01.
        XCTAssertEqual(r.onset!.timeIntervalSince(ist("23:41", nextDay: false)), 0, accuracy: 10 * 60)
        let up = try XCTUnwrap(r.episodes.first { $0.kind == .up })
        XCTAssertLessThanOrEqual(up.start, ist("02:00", nextDay: true))
        XCTAssertGreaterThanOrEqual(up.end, ist("02:15", nextDay: true))
        XCTAssertGreaterThan(up.steps ?? 0, 500)
        XCTAssertEqual(r.wake!.timeIntervalSince(ist("08:01", nextDay: true)), 0, accuracy: 10 * 60)
        // Morning prompts: the 2 am walk is among the interruptions to ask about.
        let ask = A.interruptionsToAsk(r)
        XCTAssertTrue(ask.contains { $0.kind == .up && $0.start == up.start })
    }

    func testThresholdsSelfCalibrateToTheStrapNoiseFloor() throws {
        let (minutes, f) = try golden()
        let base = A.analyze(minutes, lightsOff: Date(timeIntervalSince1970: f.lights_off))
        // A noisier strap/person (3× motion everywhere) must produce the same timeline.
        let scaled = minutes.map { m -> A.Minute in var c = m; c.motion = m.motion.map { $0 * 3 }; return c }
        let r = A.analyze(scaled, lightsOff: Date(timeIntervalSince1970: f.lights_off))
        XCTAssertEqual(r.onset, base.onset)
        XCTAssertEqual(r.wake, base.wake)
        XCTAssertEqual(r.episodes.map(\.kind), base.episodes.map(\.kind))
    }

    private func synthetic(_ count: Int, motion: Double = 0.007) -> [A.Minute] {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        return (0..<count).map {
            A.Minute(start: t0.addingTimeInterval(Double($0) * 60), heartRate: 60, motion: motion,
                     steps: 0, rrIntervals: [], offWrist: false)
        }
    }

    func testIsolatedRollOverBurstsNeverBecomeUp() {
        var m = synthetic(200)
        for i in stride(from: 40, to: 160, by: 15) { m[i].steps = 55; m[i].motion = 0.4 }
        let r = A.analyze(m)
        XCTAssertFalse(r.episodes.contains { $0.kind == .up })
    }

    func testSustainedWalkingBecomesUpAndIsAsked() {
        var m = synthetic(200)
        for i in 90..<100 { m[i].steps = 90; m[i].motion = 0.8 }
        let r = A.analyze(m)
        let up = r.episodes.first { $0.kind == .up }
        XCTAssertNotNil(up)
        XCTAssertEqual(up?.steps, 900)
        XCTAssertEqual(A.interruptionsToAsk(r).first?.kind, .up)
    }

    func testOffWristMinutesAreNotWornNotSleep() {
        var m = synthetic(200)
        for i in 60..<80 { m[i].offWrist = true; m[i].heartRate = nil }
        let r = A.analyze(m)
        XCTAssertTrue(r.episodes.contains { $0.kind == .notWorn })
    }

    func testNoSustainedRestMeansNoSleepClaimed() {
        var m = synthetic(120, motion: 0.3)
        for i in m.indices { m[i].steps = i % 2 == 0 ? 30 : 0 }
        let r = A.analyze(m)
        XCTAssertNil(r.onset)
        XCTAssertTrue(r.episodes.isEmpty)
    }

    func testSensitiveLabelsAreFlagged() {
        XCTAssertTrue(AtriaNightInterruptionLabel.intimacy.isSensitive)
        XCTAssertFalse(AtriaNightInterruptionLabel.bathroom.isSensitive)
        XCTAssertEqual(AtriaNightInterruptionLabel.allCases.count, 8)
    }
}
