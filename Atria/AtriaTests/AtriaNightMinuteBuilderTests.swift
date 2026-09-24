import XCTest
@testable import Atria

/// Per-minute night builder (issue #50): real on-device samples in, analyzer
/// minutes out. Honesty (no invented minutes), the population rule (scale
/// invariance), the sleep-anchored morning prompt, and the baseline store.
final class AtriaNightMinuteBuilderTests: XCTestCase {
    typealias B = AtriaNightMinuteBuilder

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 60))

    // MARK: Minute assembly

    func testHeartRateIsAMinuteMeanAndEmptyMinutesStayNil() {
        let window = DateInterval(start: t0, duration: 3 * 60)
        let hr: [B.HeartRateSample] = [
            .init(t: t0.addingTimeInterval(5), bpm: 60),
            .init(t: t0.addingTimeInterval(35), bpm: 64),
            .init(t: t0.addingTimeInterval(150), bpm: 70),
            .init(t: t0.addingTimeInterval(151), bpm: 0),      // withheld / zero never counts
            .init(t: t0.addingTimeInterval(152), bpm: 400),    // implausible
        ]
        let build = B.build(window: window, heartRate: hr, motion: [], rr: [])
        XCTAssertEqual(build.minutes.count, 3)
        XCTAssertEqual(build.minutes[0].heartRate, 62)
        XCTAssertNil(build.minutes[1].heartRate, "a minute with no sample is never filled in")
        XCTAssertEqual(build.minutes[2].heartRate, 70)
        XCTAssertEqual(build.coverage.heartRateMinutes, 2)
        XCTAssertTrue(build.minutes.allSatisfy { !$0.offWrist }, "no per-minute contact record: never claimed")
        XCTAssertTrue(build.minutes.allSatisfy { $0.motion == nil })
        XCTAssertTrue(build.coverage.hasNoMotion)
    }

    func testMotionScalarAndCounterTicksPerMinute() {
        let window = DateInterval(start: t0, duration: 4 * 60)
        var motion: [B.MotionSample] = []
        // Minute 0: rest, counter silent.
        for s in stride(from: 0, to: 60, by: 1) {
            motion.append(.init(timestamp: t0.timeIntervalSince1970 + Double(s), tick: 100, scalar: 0.007))
        }
        // Minute 1: moving, counter advances 2 per second, wraps at 65 536.
        for s in stride(from: 60, to: 120, by: 1) {
            let tick = (65_500 + (s - 60) * 2) % 65_536
            motion.append(.init(timestamp: t0.timeIntervalSince1970 + Double(s), tick: tick, scalar: 0.3))
        }
        // Minute 2: no rows at all. Minute 3: one row after a >90 s gap and
        // a replay jump: neither may produce ticks.
        motion.append(.init(timestamp: t0.timeIntervalSince1970 + 200, tick: 9_000, scalar: nil))
        let build = B.build(window: window, heartRate: [], motion: motion, rr: [])
        XCTAssertEqual(build.minutes[0].motion ?? -1, 0.007, accuracy: 1e-9)
        XCTAssertEqual(build.minutes[0].steps, 0)
        XCTAssertEqual(build.minutes[1].motion ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(build.minutes[1].steps, 118, "59 in-minute pairs × 2; the wrap is continuous")
        XCTAssertNil(build.minutes[2].motion)
        XCTAssertEqual(build.minutes[2].steps, 0)
        XCTAssertNil(build.minutes[3].motion, "a row without the scalar is unknown motion, not still")
        XCTAssertEqual(build.minutes[3].steps, 0)
        XCTAssertEqual(build.coverage.motionMinutes, 2)
    }

    func testRRIsBucketedByBeatTime() {
        let window = DateInterval(start: t0, duration: 2 * 60)
        let rr: [B.RRSample] = [.init(t: t0.addingTimeInterval(10), ms: 900),
                                .init(t: t0.addingTimeInterval(70), ms: 910),
                                .init(t: t0.addingTimeInterval(500), ms: 920)]
        let build = B.build(window: window, heartRate: [], motion: [], rr: rr)
        XCTAssertEqual(build.minutes.map(\.rrIntervals), [[900], [910]])
    }

    func testWindowPadsAndCaps() throws {
        let start = t0, end = t0.addingTimeInterval(8 * 3_600)
        let w = try XCTUnwrap(B.window(sleepStart: start, sleepEnd: end))
        XCTAssertEqual(w.start, start.addingTimeInterval(-30 * 60))
        XCTAssertEqual(w.end, end.addingTimeInterval(30 * 60))
        let huge = try XCTUnwrap(B.window(sleepStart: start, sleepEnd: t0.addingTimeInterval(30 * 3_600)))
        XCTAssertEqual(huge.duration, Double(B.maximumMinutes) * 60)
        XCTAssertNil(B.window(sleepStart: end, sleepEnd: start))
    }

    // MARK: End to end (synthetic 1 Hz stores)

    /// 23:00 lights-out-ish rest, a 20-minute walk at ~02:00, wake ~07:00.
    private func syntheticNight(scalarScale: Double = 1, withMotion: Bool = true)
        -> (request: AtriaNightTimelineRequest, window: DateInterval,
            hr: [B.HeartRateSample], motion: [B.MotionSample]) {
        let sleepStart = t0
        let sleepEnd = t0.addingTimeInterval(8 * 3_600)
        let request = AtriaNightTimelineRequest(sleepID: "s1", start: sleepStart, end: sleepEnd,
                                                eventTimeZoneIdentifier: "UTC")
        let window = B.window(sleepStart: sleepStart, sleepEnd: sleepEnd)!
        var hr: [B.HeartRateSample] = []
        var motion: [B.MotionSample] = []
        var tick = 0
        var s = window.start.timeIntervalSince1970
        while s < window.end.timeIntervalSince1970 {
            let offset = s - sleepStart.timeIntervalSince1970
            let awake = offset < 0 || offset >= 8 * 3_600
            let walking = (3 * 3_600..<(3 * 3_600 + 20 * 60)).contains(offset)
            let jitter = Double(Int(s) % 7) * 0.0003
            let scalar = (awake ? 0.2 : walking ? 0.35 : 0.007 + jitter) * scalarScale
            if walking || (awake && Int(s) % 3 == 0) { tick = (tick + 2) % 65_536 }
            if withMotion {
                motion.append(.init(timestamp: s, tick: tick, scalar: scalar))
            }
            hr.append(.init(t: Date(timeIntervalSince1970: s), bpm: awake || walking ? 80 : 58))
            s += 1
        }
        return (request, window, hr, motion)
    }

    func testSyntheticNightIsPlacedWithTheWalkAsUp() throws {
        let n = syntheticNight()
        let loaded = AtriaNightTimelineLoader.assemble(n.request, window: n.window,
                                                       heartRate: n.hr, motion: n.motion, rr: [])
        let r = loaded.model.result
        let onset = try XCTUnwrap(r.onset), wake = try XCTUnwrap(r.wake)
        XCTAssertLessThan(abs(onset.timeIntervalSince(n.request.start)), 5 * 60)
        XCTAssertLessThan(abs(wake.timeIntervalSince(n.request.end)), 5 * 60)
        let up = try XCTUnwrap(r.episodes.first { $0.kind == .up })
        XCTAssertEqual(up.start.timeIntervalSince(n.request.start), 3 * 3_600, accuracy: 120)
        XCTAssertEqual(r.sleepingHeartRate, 58)
        XCTAssertNil(loaded.model.unavailableReason)
        XCTAssertNil(loaded.model.motionNote)
        let summary = try XCTUnwrap(loaded.summary)
        XCTAssertGreaterThanOrEqual(summary.coverage, 0.99)
        XCTAssertEqual(AtriaNightTimelineAnalyzer.interruptionsToAsk(r).map(\.kind), [.up])
    }

    /// Population rule: a strap whose scalar reads 10× higher places the same
    /// night — thresholds are relative to the night's own floor.
    func testScalarScaleDoesNotChangeTheNight() {
        let a = syntheticNight(scalarScale: 1), b = syntheticNight(scalarScale: 10)
        let ra = AtriaNightTimelineLoader.assemble(a.request, window: a.window, heartRate: a.hr, motion: a.motion, rr: []).model.result
        let rb = AtriaNightTimelineLoader.assemble(b.request, window: b.window, heartRate: b.hr, motion: b.motion, rr: []).model.result
        XCTAssertEqual(ra.onset, rb.onset)
        XCTAssertEqual(ra.wake, rb.wake)
        XCTAssertEqual(ra.episodes.map(\.kind), rb.episodes.map(\.kind))
    }

    func testNoMotionNightSaysSoAndClaimsNothing() {
        let n = syntheticNight(withMotion: false)
        let loaded = AtriaNightTimelineLoader.assemble(n.request, window: n.window,
                                                       heartRate: n.hr, motion: [], rr: [])
        XCTAssertNil(loaded.model.result.onset, "HR alone never places sleep here")
        XCTAssertNil(loaded.summary)
        XCTAssertEqual(loaded.model.unavailableReason, "No motion data for this night.")
        XCTAssertTrue(AtriaNightTimelineAnalyzer.interruptionsToAsk(loaded.model.result).isEmpty)

        let empty = AtriaNightTimelineLoader.assemble(n.request, window: n.window,
                                                      heartRate: [], motion: [], rr: [])
        XCTAssertEqual(empty.model.unavailableReason, "No strap data for this night yet.")
    }

    func testPartialMotionIsFlagged() {
        let n = syntheticNight()
        // Keep motion only for the first 40 % of the window.
        let cut = n.window.start.timeIntervalSince1970 + n.window.duration * 0.4
        let loaded = AtriaNightTimelineLoader.assemble(n.request, window: n.window, heartRate: n.hr,
                                                       motion: n.motion.filter { $0.timestamp < cut }, rr: [])
        XCTAssertTrue(loaded.coverage.motionIsPartial)
        if AtriaNightTimelinePresentation(loaded.model) != nil {
            XCTAssertEqual(loaded.model.motionNote, "Motion missing for part of the night.")
        }
    }

    /// Private golden night (untracked; set ATRIA_PRIVATE_NIGHT_FIXTURE or keep
    /// it in AtriaTests/Fixtures). Expands the per-minute fixture into 1 Hz
    /// store-shaped samples and checks the builder reproduces the analysis.
    func testGoldenNightRoundTripsThroughTheBuilder() throws {
        struct M: Decodable { let t: Double; let hr: Double?; let motion: Double?; let steps: Int; let rr: [Int]; let off_wrist: Bool }
        struct F: Decodable { let minutes: [M] }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [ProcessInfo.processInfo.environment["ATRIA_PRIVATE_NIGHT_FIXTURE"],
                          root.appendingPathComponent("Atria/AtriaTests/Fixtures/whoop4-night-2026-09-23-minutes.json").path]
            .compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("private golden night fixture not present")
        }
        let f = try JSONDecoder().decode(F.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Reference: the analyzer on the fixture minutes, ignoring off-wrist
        // (the builder never has per-minute contact).
        let reference = AtriaNightTimelineAnalyzer.analyze(f.minutes.map {
            .init(start: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr, motion: $0.motion,
                  steps: $0.steps, rrIntervals: $0.rr, offWrist: false)
        })
        var hr: [B.HeartRateSample] = [], motion: [B.MotionSample] = [], rr: [B.RRSample] = []
        var tick = 0
        for m in f.minutes {
            if let v = m.hr { hr.append(.init(t: Date(timeIntervalSince1970: m.t + 30), bpm: Int(v.rounded()))) }
            for (j, ms) in m.rr.enumerated() { rr.append(.init(t: Date(timeIntervalSince1970: m.t + Double(j % 60)), ms: ms)) }
            guard m.motion != nil || m.steps > 0 else { continue }
            // 60 rows in the minute; the counter advances by the minute's
            // steps across its 59 in-minute pairs, and one more pair joins
            // the next minute (carried at zero advance).
            for s in 0..<60 {
                let advance = s == 0 ? 0 : (m.steps * s / 59) - (m.steps * (s - 1) / 59)
                tick = (tick + advance) % 65_536
                motion.append(.init(timestamp: m.t + Double(s), tick: tick, scalar: m.motion))
            }
        }
        let first = f.minutes.first!.t, last = f.minutes.last!.t + 60
        let build = B.build(window: DateInterval(start: Date(timeIntervalSince1970: first),
                                                 end: Date(timeIntervalSince1970: last)),
                            heartRate: hr, motion: motion, rr: rr)
        XCTAssertEqual(build.minutes.count, f.minutes.count)
        let r = AtriaNightTimelineAnalyzer.analyze(build.minutes)
        XCTAssertEqual(r.onset, reference.onset)
        XCTAssertEqual(r.wake, reference.wake)
        XCTAssertEqual(r.episodes.map(\.kind), reference.episodes.map(\.kind))
    }

    // MARK: Sleep-anchored morning prompt

    func testMorningPromptFollowsTheWakeNotTheClock() {
        let cal = Calendar(identifier: .gregorian)
        var c = DateComponents(year: 2026, month: 8, day: 20, hour: 19, minute: 15)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")
        let wake = cal.date(from: c)!   // shifted sleeper: 13:15 → 19:15
        XCTAssertTrue(AtriaNightTimelineSource.morningPromptIsDue(wake: wake, now: wake.addingTimeInterval(45 * 60)),
                      "19:15 wake is asked that evening (the old 04–13 clock gate never asked)")
        XCTAssertTrue(AtriaNightTimelineSource.morningPromptIsDue(wake: wake, now: wake.addingTimeInterval(6 * 3_600)))
        XCTAssertFalse(AtriaNightTimelineSource.morningPromptIsDue(wake: wake, now: wake.addingTimeInterval(13 * 3_600)))
        XCTAssertFalse(AtriaNightTimelineSource.morningPromptIsDue(wake: wake, now: wake.addingTimeInterval(-60)))
    }

    // MARK: Main sleeps only; summary store

    private func night(_ id: String, start: Date, hours: Double, source: String,
                       confirmed: Bool = true) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id, day: start, start: start,
                                   end: start.addingTimeInterval(hours * 3_600),
                                   duration: hours * 3_600, restingHR: 55, hrv: nil,
                                   respiratoryRate: nil, sleepEfficiency: nil,
                                   confidence: "high", source: source, confirmed: confirmed,
                                   stageSegments: [])
    }

    func testNapsAndCandidatesNeverFeedTheTimelineOrBaseline() {
        let snapshot = SleepHistorySnapshot(nights: [
            night("nap", start: t0.addingTimeInterval(2 * 86_400), hours: 1, source: "manual_nap"),
            night("candidate", start: t0.addingTimeInterval(86_400 + 3_600), hours: 7, source: "auto_sleep", confirmed: false),
            night("main2", start: t0.addingTimeInterval(86_400), hours: 7, source: "auto_confirmed_sleep"),
            night("main1", start: t0, hours: 7, source: "manual_sleep"),
        ], confirmedCount: 3, candidateCount: 1)
        XCTAssertEqual(AtriaNightTimelineRequest.mainSleeps(in: snapshot).map(\.sleepID), ["main2", "main1"])
    }

    private func summary(_ onset: Date, hr: Double, coverage: Double = 1) -> AtriaNightSummary {
        AtriaNightSummary(night: onset, onset: onset, wake: onset.addingTimeInterval(7 * 3_600),
                          asleepMinutes: 400, disturbedMinutes: 20, interruptions: 1, ups: 0,
                          sleepingHeartRate: hr, sleepingRMSSD: nil, coverage: coverage)
    }

    func testSummaryStoreRetriesThinRecentNightsAndDropsEditedOnes() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AtriaNightMinuteBuilderTests.\(UUID())"))
        let now = t0.addingTimeInterval(3 * 86_400)
        let good = AtriaNightTimelineRequest(sleepID: "a", start: t0, end: t0.addingTimeInterval(7 * 3_600), eventTimeZoneIdentifier: nil)
        let thin = AtriaNightTimelineRequest(sleepID: "b", start: t0.addingTimeInterval(86_400),
                                             end: t0.addingTimeInterval(86_400 + 7 * 3_600), eventTimeZoneIdentifier: nil)
        AtriaNightSummaryStore.record(summary(good.start, hr: 58), for: good, now: now, defaults: defaults)
        AtriaNightSummaryStore.record(summary(thin.start, hr: 58, coverage: 0.4), for: thin, now: now, defaults: defaults)
        XCTAssertEqual(AtriaNightSummaryStore.missing([good, thin], now: now, defaults: defaults), [])
        // A day later the thin (drain-lagged) night is retried; the good one never is.
        XCTAssertEqual(AtriaNightSummaryStore.missing([good, thin], now: now.addingTimeInterval(86_401),
                                                      defaults: defaults), [thin])
        // An edited window is a new night to analyse; its stale summary drops out.
        let edited = AtriaNightTimelineRequest(sleepID: "a", start: t0.addingTimeInterval(-1_800),
                                               end: good.end, eventTimeZoneIdentifier: nil)
        XCTAssertEqual(AtriaNightSummaryStore.missing([edited], now: now, defaults: defaults), [edited])
        XCTAssertTrue(AtriaNightSummaryStore.history(for: [edited], defaults: defaults).isEmpty)
        XCTAssertEqual(AtriaNightSummaryStore.history(for: [good, thin], defaults: defaults).count, 2)
    }

    func testBaselineReportLearnsThenCompares() {
        let tonightOnset = t0.addingTimeInterval(10 * 86_400)
        let tonight = summary(tonightOnset, hr: 52)
        let three = (1...3).map { summary(tonightOnset.addingTimeInterval(-Double($0) * 86_400), hr: 58) }
        let learning = AtriaNightBaselineReport(tonight: tonight, history: three)
        XCTAssertEqual(learning.learningText, "Learning (3/5)")
        XCTAssertTrue(learning.lines.isEmpty)

        let seven = (1...7).map { summary(tonightOnset.addingTimeInterval(-Double($0) * 86_400), hr: 58 + Double($0 % 2)) }
        let compared = AtriaNightBaselineReport(tonight: tonight, history: seven)
        XCTAssertNil(compared.learningText)
        XCTAssertEqual(compared.prior.count, 7)
        XCTAssertEqual(compared.lines.first, "Sleeping heart rate 52 bpm, 7 lower than usual.")
        XCTAssertLessThanOrEqual(compared.lines.count, 3)

        let typical = AtriaNightBaselineReport(tonight: summary(tonightOnset, hr: 58), history: seven)
        XCTAssertEqual(typical.lines.first, "A typical night for you.")
    }
}
