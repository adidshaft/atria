import XCTest
@testable import Atria

/// The review-only daytime sleep detector: every gate blocks a NAMED
/// fabrication, and the owner's real day must detect.
final class AtriaDaytimeQuiescentSleepDetectorTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal
    }

    /// 15:00 IST on a fixed day — inside the daytime band.
    private var sleepStart: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 27,
                                           hour: 15))!
    }

    private func point(at t: Date, tick: Int)
        -> AtriaWhoop4MotionTickCompactStore.Point {
        .init(timestamp: t.timeIntervalSince1970, flash: 0, tick: tick,
              gravityX: 0, gravityY: 0, gravityZ: 1,
              unknownMotionScalar32: nil, identity: "TEST")
    }

    /// 1 Hz rows for `minutes` minutes at `ticksPerMinute` counter advance.
    private func rows(from: Date, minutes: Int, ticksPerMinute: Int,
                      startTick: Int = 0)
        -> [AtriaWhoop4MotionTickCompactStore.Point] {
        var out: [AtriaWhoop4MotionTickCompactStore.Point] = []
        var tick = startTick
        for m in 0..<minutes {
            for s in stride(from: 0, to: 60, by: 6) {
                out.append(point(at: from.addingTimeInterval(
                    Double(m * 60 + s)), tick: tick))
                if s % max(6, 60 / max(ticksPerMinute, 1)) == 0 {
                    tick += max(0, ticksPerMinute / 10)
                }
            }
        }
        return out
    }

    private func hr(_ points: [(from: Date, minutes: Int, bpm: Double)])
        -> [Int: Double] {
        var out: [Int: Double] = [:]
        for series in points {
            let start = Int(series.from.timeIntervalSince1970 / 60)
            for m in 0..<series.minutes { out[start + m] = series.bpm }
        }
        return out
    }

    /// The owner's measured day: 5 h quiet at ~1 tick/min, HR 62 inside vs
    /// 76 around, full coverage.
    private func ownersDay() -> (
        points: [AtriaWhoop4MotionTickCompactStore.Point],
        hr: [Int: Double]
    ) {
        let awakeBefore = sleepStart.addingTimeInterval(-3 * 3_600)
        let wakeAfter = sleepStart.addingTimeInterval(5 * 3_600)
        var points = rows(from: awakeBefore, minutes: 180, ticksPerMinute: 12)
        points += rows(from: sleepStart, minutes: 300, ticksPerMinute: 1,
                       startTick: 40_000)
        points += rows(from: wakeAfter, minutes: 180, ticksPerMinute: 15,
                       startTick: 50_000)
        let hrMap = hr([(awakeBefore, 180, 76), (sleepStart, 300, 62),
                        (wakeAfter, 180, 78)])
        return (points, hrMap)
    }

    private func detect(
        points: [AtriaWhoop4MotionTickCompactStore.Point],
        hr: [Int: Double],
        excluded: [DateInterval] = [],
        use: [DateInterval] = []
    ) -> AtriaDaytimeQuiescentSleepDetector.Candidate? {
        AtriaDaytimeQuiescentSleepDetector.detect(
            points: points, hrMinutesByBucket: hr, excluded: excluded,
            sustainedDeviceUse: use,
            now: sleepStart.addingTimeInterval(8 * 3_600),
            calendar: calendar)
    }

    // MARK: - The owner's day detects

    func testARealDaytimeSleepProducesACandidate() {
        let day = ownersDay()
        let candidate = detect(points: day.points, hr: day.hr)
        XCTAssertNotNil(candidate)
        XCTAssertGreaterThan(candidate!.observedQuietSeconds, 3.5 * 3_600)
        XCTAssertLessThan(candidate!.meanInWindowHR, 66)
        XCTAssertGreaterThan(candidate!.meanSurroundHR - candidate!.meanInWindowHR,
                             AtriaDaytimeQuiescentSleepDetector.minimumHRDepressionBPM)
    }

    func testTheNightIsReviewOnlyAndCreditsObservedQuietNotSpan() {
        let day = ownersDay()
        let candidate = detect(points: day.points, hr: day.hr)!
        let night = AtriaDaytimeQuiescentSleepDetector.night(
            for: candidate, calendar: calendar,
            timeZoneIdentifier: "Asia/Kolkata")
        XCTAssertFalse(night.confirmed)
        XCTAssertEqual(night.confidence, "review_needed")
        XCTAssertEqual(night.source, "daytime_quiescence_review")
        XCTAssertLessThanOrEqual(night.duration,
                                 night.end!.timeIntervalSince(night.start!) + 1,
                                 "duration is observed quiet, never more than span")
    }

    // MARK: - Named fabrications stay blocked

    func testAStrapOnATableIsRefusedByTheHRPresenceFloor() {
        // Flash records motion rows regardless of wear: zero ticks, zero HR.
        let day = ownersDay()
        var hrMap = day.hr
        // Strip ALL in-window HR — off-wrist HR is withheld at decode.
        let lo = Int(sleepStart.timeIntervalSince1970 / 60)
        for m in lo..<(lo + 300) { hrMap.removeValue(forKey: m) }
        XCTAssertNil(detect(points: day.points, hr: hrMap),
                     "quiet motion with no accepted HR is a table, not a sleep")
    }

    func testAStillPassengerAtAwakeHRIsRefusedByTheDepressionGate() {
        let day = ownersDay()
        var hrMap = day.hr
        let lo = Int(sleepStart.timeIntervalSince1970 / 60)
        for m in lo..<(lo + 300) { hrMap[m] = 75 }   // quiet wrist, awake heart
        XCTAssertNil(detect(points: day.points, hr: hrMap),
                     "the repo already burned once on HR-only quiet awake time")
    }

    func testASleepBracketedByCaptureVoidWaitsForTheDrain() {
        let day = ownersDay()
        var hrMap = day.hr
        // Remove the surround: unknown is not evidence of wakefulness either.
        for m in hrMap.keys where m < Int(sleepStart.timeIntervalSince1970 / 60)
            || m >= Int(sleepStart.timeIntervalSince1970 / 60) + 300 {
            hrMap.removeValue(forKey: m)
        }
        XCTAssertNil(detect(points: day.points, hr: hrMap),
                     "no surround comparison -> refuse now, re-detect when "
                         + "the drain lands the surround")
    }

    func testAConfirmedNapInsideTheWindowVetoesTheOverlappingPart() {
        let day = ownersDay()
        let nap = DateInterval(start: sleepStart.addingTimeInterval(3_600),
                               end: sleepStart.addingTimeInterval(2 * 3_600))
        let candidate = detect(points: day.points, hr: day.hr, excluded: [nap])
        if let candidate {
            XCTAssertLessThan(
                candidate.window.intersection(with: nap)?.duration ?? 0, 61,
                "a confirmed nap's window must not be re-surfaced inside a "
                    + "bigger candidate")
        }
    }

    func testSustainedPhoneUseVetoesButABriefCheckDoesNot() {
        let day = ownersDay()
        let briefCheck = DateInterval(
            start: sleepStart.addingTimeInterval(2 * 3_600),
            end: sleepStart.addingTimeInterval(2 * 3_600 + 120))
        XCTAssertNotNil(detect(points: day.points, hr: day.hr,
                               use: [briefCheck]),
                        "a 2-minute mid-sleep phone check must not kill it")
    }

    func testANapSizedWindowBelongsToTheNapLane() {
        // 150 quiet minutes, not 175: the core's anchor-based window bounds
        // can present a 175-minute quiet block as a span just over three
        // hours — which is legitimately THIS lane's, because the nap lane
        // caps at a 3 h SPAN (no overlap between lanes, and no gap). The
        // first version of this test asserted the wrong owner for that
        // boundary shape and failed against correct code.
        let awakeBefore = sleepStart.addingTimeInterval(-3 * 3_600)
        var points = rows(from: awakeBefore, minutes: 180, ticksPerMinute: 12)
        points += rows(from: sleepStart, minutes: 150, ticksPerMinute: 1,
                       startTick: 40_000)
        let wake = sleepStart.addingTimeInterval(150 * 60)
        points += rows(from: wake, minutes: 180, ticksPerMinute: 14,
                       startTick: 50_000)
        let hrMap = hr([(awakeBefore, 180, 76), (sleepStart, 150, 62),
                        (wake, 180, 78)])
        XCTAssertNil(detect(points: points, hr: hrMap),
                     "a nap-sized window is the nap lane's, not this one's")
    }

    // MARK: - Owner's real shards (skips when absent)

    func testTheRealTwentySeventhDetects() throws {
        let dir = "/private/tmp/claude-501/-Users-amanpandey-projects-atria/"
            + "90cb7ac0-fd92-46ca-acf1-b136c273c440/scratchpad/pull7/"
            + "whoop4-motion-compact-v1"
        let stress = "/private/tmp/claude-501/-Users-amanpandey-projects-atria/"
            + "90cb7ac0-fd92-46ca-acf1-b136c273c440/scratchpad/pull7/"
            + "stress-history-v3"
        guard FileManager.default.fileExists(atPath: dir),
              FileManager.default.fileExists(atPath: stress) else {
            throw XCTSkip("owner pull not present")
        }
        let store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: URL(fileURLWithPath: dir))
        let strap = "C125C62E-C432-53E7-BD19-9761251B2C3E"
        let apple = 978_307_200.0
        var hrMap: [Int: Double] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: stress)
        where file.hasSuffix(".json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: stress)
                .appendingPathComponent(file))
            guard let obj = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let points = obj["p"] as? [[String: Any]] else { continue }
            for p in points {
                guard let f = p["f"] as? [String: Any],
                      let date = f["date"] as? Double,
                      let hr = f["meanHeartRate"] as? Double else { continue }
                hrMap[Int((date + apple) / 60)] = hr
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = cal.date(from: DateComponents(
            year: 2026, month: 8, day: 27, hour: 21))!

        var candidate: AtriaDaytimeQuiescentSleepDetector.Candidate?
        let done = expectation(description: "detect")
        DispatchQueue.global(qos: .userInitiated).async {
            let points = store.decodedPoints(
                start: now.addingTimeInterval(-26 * 3_600), end: now,
                strapIdentifier: strap)
            candidate = AtriaDaytimeQuiescentSleepDetector.detect(
                points: points, hrMinutesByBucket: hrMap, excluded: [],
                sustainedDeviceUse: [], now: now, calendar: cal)
            done.fulfill()
        }
        wait(for: [done], timeout: 240)

        let found = try XCTUnwrap(candidate,
                                  "the owner's real 15:00-20:00 sleep must detect")
        let hour = cal.component(.hour, from: found.start)
        XCTAssertTrue((13...17).contains(hour),
                      "starts mid-afternoon; got hour \(hour)")
        XCTAssertGreaterThan(found.observedQuietSeconds, 3 * 3_600)
        XCTAssertLessThan(found.meanInWindowHR, found.meanSurroundHR - 8)
    }
}
