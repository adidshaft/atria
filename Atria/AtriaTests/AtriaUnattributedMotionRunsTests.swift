import XCTest
@testable import Atria

/// The unverified-movement detector and the arbitration it feeds. Fixtures are
/// modelled on the MEASURED device shapes of 2026-08-27, not invented ones.
final class AtriaUnattributedMotionRunsTests: XCTestCase {

    // MINUTE-ALIGNED, and the alignment is load-bearing: an earlier value
    // (1_756_000_000, not divisible by 60) made every fixture "minute"
    // straddle two real minute buckets, splitting rates across them — two
    // tests failed on their own arithmetic before any code was wrong.
    private let base = 1_756_000_020

    private func point(minute: Int, second: Int, tick: Int)
        -> AtriaWhoop4MotionTickCompactStore.Point {
        .init(timestamp: TimeInterval(base + minute * 60 + second),
              flash: UInt32(minute * 60 + second),
              tick: tick,
              gravityX: 0, gravityY: 0, gravityZ: 1,
              unknownMotionScalar32: nil,
              identity: "TEST")
    }

    /// Rows at 1 Hz advancing `rate` ticks/min across `minutes`.
    private func steady(fromMinute: Int, minutes: Int, rate: Int,
                        startTick: Int = 0)
        -> [AtriaWhoop4MotionTickCompactStore.Point] {
        var points: [AtriaWhoop4MotionTickCompactStore.Point] = []
        var tick = startTick
        for m in 0..<minutes {
            for s in stride(from: 0, to: 60, by: 12) {
                points.append(point(minute: fromMinute + m, second: s, tick: tick))
                tick += rate / 5
            }
        }
        return points
    }

    private func minuteStart(_ minute: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval((base / 60 + minute) * 60))
    }

    // MARK: - minuteTickTotals

    func testPerMinuteTotalsApplyTheReducersSanityBound() {
        // A wrap/reset delta larger than max(12, dur*12) must not credit.
        let points = [point(minute: 0, second: 0, tick: 100),
                      point(minute: 0, second: 1, tick: 400)]
        XCTAssertTrue(AtriaUnattributedMotionRuns.minuteTickTotals(points).isEmpty)
    }

    func testAUInt16WrapStillCountsItsRealDelta() {
        let points = [point(minute: 0, second: 0, tick: 65_530),
                      point(minute: 0, second: 1, tick: 2)]
        let totals = AtriaUnattributedMotionRuns.minuteTickTotals(points)
        XCTAssertEqual(totals.values.first, 8)
    }

    // MARK: - The measured shapes

    func testTheMealShapeBecomesOneCluster() {
        // 26 Aug 21:31-21:45: fourteen minutes at ~74 ticks/min.
        let clusters = AtriaUnattributedMotionRuns.clusters(
            minuteTicks: AtriaUnattributedMotionRuns.minuteTickTotals(
                steady(fromMinute: 0, minutes: 14, rate: 75)),
            explained: [])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertGreaterThan(clusters[0].estimatedSteps, 700,
                             "the meal was worth ~890 phantom steps")
        XCTAssertEqual(clusters[0].activeMinutes, 14)
    }

    func testSedentaryDriftNeverBecomesACluster() {
        // All-day 10-15 ticks/min drift — the noise floor, below the active
        // minute bar.
        let clusters = AtriaUnattributedMotionRuns.clusters(
            minuteTicks: AtriaUnattributedMotionRuns.minuteTickTotals(
                steady(fromMinute: 0, minutes: 120, rate: 15)),
            explained: [])
        XCTAssertTrue(clusters.isEmpty)
    }

    func testNearbyBurstsJoinAndDistantOnesSplit() {
        // Rate 70, not 60: the fixture's last minute only accrues 4 of its 5
        // row-pairs, so a 4-minute burst at 60 totals 228 ticks — BELOW the
        // 250-tick question floor — and the split cluster was correctly
        // filtered rather than counted. The test caught its author's
        // arithmetic twice (the first time on minute alignment).
        var points = steady(fromMinute: 0, minutes: 4, rate: 70)
        points += steady(fromMinute: 19, minutes: 4, rate: 70,
                         startTick: 10_000)   // 15-min gap: joins
        points += steady(fromMinute: 50, minutes: 4, rate: 70,
                         startTick: 20_000)   // 27-min gap: splits
        let clusters = AtriaUnattributedMotionRuns.clusters(
            minuteTicks: AtriaUnattributedMotionRuns.minuteTickTotals(points),
            explained: [])
        XCTAssertEqual(clusters.count, 2,
                       "a meal pauses and resumes; one question, not three — "
                           + "but a separate later burst is a separate question")
    }

    func testALabelledWorkoutWindowIsNeverAskedAbout() {
        let points = steady(fromMinute: 0, minutes: 10, rate: 70)
        let workout = DateInterval(start: minuteStart(0), end: minuteStart(10))
        XCTAssertTrue(AtriaUnattributedMotionRuns.clusters(
            minuteTicks: AtriaUnattributedMotionRuns.minuteTickTotals(points),
            explained: [workout]).isEmpty,
                      "a labelled block already explains its arm motion")
    }

    func testATinyBurstIsBelowTheQuestionFloor() {
        // Three minutes at 26 ticks — 78 ticks, ~66 steps. Not worth asking.
        let clusters = AtriaUnattributedMotionRuns.clusters(
            minuteTicks: AtriaUnattributedMotionRuns.minuteTickTotals(
                steady(fromMinute: 0, minutes: 3, rate: 26)),
            explained: [])
        XCTAssertTrue(clusters.isEmpty)
    }

    // MARK: - Arbitration store

    private func temporaryStore() -> AtriaNonGaitArbitrationStore {
        AtriaNonGaitArbitrationStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("arb-\(UUID().uuidString).json"))
    }

    func testAnswersPersistAndFeedTheRightSets() {
        let store = temporaryStore()
        let meal = DateInterval(start: minuteStart(0), end: minuteStart(14))
        let walk = DateInterval(start: minuteStart(30), end: minuteStart(45))
        store.record(window: meal, verdict: .notWalking)
        store.record(window: walk, verdict: .walking)

        XCTAssertEqual(store.notWalkingWindows(), [meal],
                       "only Not-walking joins the exclusion feed")
        XCTAssertEqual(Set(store.arbitratedWindows()), Set([meal, walk]),
                       "both verdicts stop the asking")
    }

    func testChangingAnAnswerReplacesRatherThanDuplicates() {
        let store = temporaryStore()
        let window = DateInterval(start: minuteStart(0), end: minuteStart(14))
        store.record(window: window, verdict: .walking)
        store.record(window: window, verdict: .notWalking)
        XCTAssertEqual(store.answers().count, 1)
        XCTAssertEqual(store.notWalkingWindows(), [window])
    }

    // MARK: - Owner's real shards (skips when absent)

    func testTheRealNoWalkEveningIsDetectedAndTheWalkIsNot() throws {
        let dir = "/private/tmp/claude-501/-Users-amanpandey-projects-atria/"
            + "90cb7ac0-fd92-46ca-acf1-b136c273c440/scratchpad/pull6/"
            + "whoop4-motion-compact-v1"
        guard FileManager.default.fileExists(atPath: dir) else {
            throw XCTSkip("owner shard pull not present")
        }
        let store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: URL(fileURLWithPath: dir))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        func ist(_ d: Int, _ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 8, day: d,
                                          hour: h, minute: m))!
        }
        let strap = "C125C62E-C432-53E7-BD19-9761251B2C3E"
        let walkWindow = DateInterval(start: ist(24, 22, 32), end: ist(24, 22, 53))

        var evening: [AtriaUnattributedMotionRuns.Cluster] = []
        var aroundWalk: [AtriaUnattributedMotionRuns.Cluster] = []
        let done = expectation(description: "reads")
        DispatchQueue.global(qos: .userInitiated).async {
            let eveningPoints = store.decodedPoints(
                start: ist(26, 20, 30), end: ist(27, 1, 30),
                strapIdentifier: strap)
            evening = AtriaUnattributedMotionRuns.clusters(
                minuteTicks: AtriaUnattributedMotionRuns
                    .minuteTickTotals(eveningPoints),
                explained: [])
            let walkPoints = store.decodedPoints(
                start: ist(24, 22, 25), end: ist(24, 23, 0),
                strapIdentifier: strap)
            aroundWalk = AtriaUnattributedMotionRuns.clusters(
                minuteTicks: AtriaUnattributedMotionRuns
                    .minuteTickTotals(walkPoints),
                explained: [walkWindow])
            done.fulfill()
        }
        wait(for: [done], timeout: 180)

        let flagged = evening.reduce(0) { $0 + $1.estimatedSteps }
        XCTAssertGreaterThanOrEqual(evening.count, 1,
                                    "the no-walk evening must surface for review")
        XCTAssertGreaterThan(flagged, 1_500,
                             "the evening carried ~3.8k phantom steps; most "
                                 + "must be inside reviewable clusters")
        // Strict interior overlap, not `intersects`: a real unexplained
        // cluster BEGINS the minute the labelled walk ends (22:53, the walk's
        // untracked tail) and touching endpoints must not count against the
        // detector — that cluster is exactly what review exists for.
        let interiorOverlap = aroundWalk.compactMap {
            $0.window.intersection(with: walkWindow)?.duration
        }.max() ?? 0
        XCTAssertLessThan(interiorOverlap, 60,
                          "the labelled walk explains itself and is never "
                              + "asked about")
    }
}

/// The review must come to the wearer, not wait behind a sheet they may never
/// open — a full wear-day produced ~5,000 unarbitrated steps and the owner
/// reported "no review cards".
extension AtriaUnattributedMotionRunsTests {
    func testTodayKnocksWhenUnverifiedMovementAccumulates() throws {
        let today = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaTodayScreen.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(today.contains("if unverifiedMovementSteps >= 300 {"),
                      "the banner mounts once enough unarbitrated movement exists")
        XCTAssertTrue(today.contains("showStrapStepsDetail = true"),
                      "and routes to the sheet that holds the review")
        XCTAssertTrue(today.contains(
            "AtriaNonGaitArbitrationStore.didChangeNotification"),
                      "an answer in the sheet must clear the banner promptly")
    }
}
