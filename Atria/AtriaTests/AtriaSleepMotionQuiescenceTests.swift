import XCTest
@testable import Atria

/// The numbers pinned here are measurements from the owner's own drained
/// history (2026-08-22…25), scored against the sleeps and workouts the app
/// itself had already confirmed:
///
/// | state                | stillness fraction | mean ticks/min | longest quiet run |
/// |----------------------|--------------------|----------------|-------------------|
/// | awake, sedentary     | 0.76 – 0.83        |  8.2 – 12.3    | 20 – 56 min       |
/// | asleep (confirmed)   | 0.91 – 1.00        |  0.05 – 0.80   | 87 – 193 min      |
/// | workout (confirmed)  | 0.15               | 66.1           | —                 |
final class AtriaSleepMotionQuiescenceTests: XCTestCase {

    private typealias Core = AtriaSleepMotionQuiescence

    private let base = Date(timeIntervalSince1970: 1_787_572_800)

    /// `count` minutes from `offset`, each carrying `ticks`.
    private func minutes(from offset: Int,
                         count: Int,
                         ticks: Int,
                         covered: TimeInterval = 60) -> [Core.Minute] {
        (0..<count).map {
            Core.Minute(start: base.addingTimeInterval(TimeInterval((offset + $0) * 60)),
                        ticks: ticks,
                        coveredSeconds: covered)
        }
    }

    // MARK: - The separation the rule rests on

    func testSleepRateProducesAWindow() {
        // 0.4 ticks/min sits inside the confirmed-sleep band (0.05–0.80).
        var input: [Core.Minute] = []
        for index in 0..<240 {
            input += minutes(from: index, count: 1, ticks: index % 5 == 0 ? 2 : 0)
        }
        let windows = Core.quiescentWindows(minutes: input)
        XCTAssertEqual(windows.count, 1)
        guard let window = windows.first else { return }
        XCTAssertLessThan(window.meanTicksPerMinute, 0.8)
        XCTAssertGreaterThanOrEqual(window.interval.duration, 90 * 60)
    }

    func testSedentaryAwakeRateProducesNothing() {
        // 10 ticks/min — squarely in the measured awake-sedentary band. This is
        // the case every stillness-fraction rule got wrong.
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 480, ticks: 10))
        XCTAssertTrue(windows.isEmpty,
                      "a sedentary evening must never read as sleep")
    }

    func testWorkoutRateProducesNothing() {
        // 66 ticks/min — the confirmed strength block.
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 120, ticks: 66))
        XCTAssertTrue(windows.isEmpty)
    }

    func testTheBandBetweenSleepAndSedentaryIsRejected() {
        // 4 ticks/min: above the quiet bound, below sedentary. Fail closed.
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 300, ticks: 4))
        XCTAssertTrue(windows.isEmpty)
    }

    // MARK: - Missing data is never quiet

    func testUncoveredMinutesCannotManufactureAWindow() {
        // The 2026-08-23 shape: no rows at all. HR was streaming through it, so
        // "no motion rows" means "not drained", never "not moving".
        let absent = minutes(from: 0, count: 480, ticks: 0, covered: 0)
        XCTAssertTrue(Core.quiescentWindows(minutes: absent).isEmpty,
                      "undrained motion must not become sleep")
    }

    func testAWindowIsNotScoredWhenTooLittleOfItIsCovered() {
        // Quiet minutes, but only every third one exists: below the 80%
        // rolling-coverage floor, so nothing is scored.
        var sparse: [Core.Minute] = []
        for index in stride(from: 0, to: 480, by: 3) {
            sparse += minutes(from: index, count: 1, ticks: 0)
        }
        XCTAssertTrue(Core.quiescentWindows(minutes: sparse).isEmpty)
    }

    func testAHoleInTheMiddleDoesNotExtendAWindowAcrossIt() {
        // Two quiet blocks with a fully undrained 4-hour hole between them.
        let first = minutes(from: 0, count: 150, ticks: 0)
        let second = minutes(from: 390, count: 150, ticks: 0)
        let windows = Core.quiescentWindows(minutes: first + second)
        XCTAssertEqual(windows.count, 2,
                       "an undrained hole must split, never bridge")
    }

    // MARK: - Defects found by adversarial review (all three executed, not theorised)

    func testAWindowNeverExtendsPastTheLastDrainedMinute() {
        // An anchor is admitted with only `required` of `span` buckets present,
        // so the rule's reach could end in minutes holding no rows at all —
        // the shape at the trailing edge of a drain. Reporting to that reach
        // presented never-drained time as quiescent.
        let drained = minutes(from: 0, count: 200, ticks: 0)
        guard let window = Core.quiescentWindows(minutes: drained).first else {
            return XCTFail("expected a window")
        }
        let lastDrained = base.addingTimeInterval(200 * 60)
        XCTAssertLessThanOrEqual(window.interval.end, lastDrained,
                                 "the interval must stop at real data")
        XCTAssertEqual(window.coverageFraction, 1.0, accuracy: 0.0001,
                       "a fully drained block must report full coverage")
    }

    func testAnInventedTailCannotBeWhatClearsTheDurationFloor() {
        // Executed proof from the review: 84 covered quiet minutes and nothing
        // after them reported a 90-minute window — it existed ONLY because of
        // 6 undrained minutes. 83 reported nothing. Both must now be empty.
        for count in [83, 84, 89] {
            XCTAssertTrue(
                Core.quiescentWindows(minutes: minutes(from: 0, count: count, ticks: 0)).isEmpty,
                "\(count) drained minutes cannot become a 90-minute window"
            )
        }
        // And the honest boundary still works from real data alone.
        XCTAssertEqual(
            Core.quiescentWindows(minutes: minutes(from: 0, count: 90, ticks: 0)).count, 1
        )
    }

    func testTheOverlapClampCannotReExtendPastTheLastDrainedMinute() {
        // The two clamps interact. The overlap clamp assigns an end taken from
        // the NEXT run's first anchor, which is not guaranteed to be covered,
        // so running it after the tail clamp silently undid the tail clamp.
        //
        // Reviewer's exact reproducing input: 80 quiet minutes, then a
        // 29-minute stretch at 3 ticks/min (just above the 2.0 quiet bound)
        // whose minutes 89 and 90 hold NO rows, then quiet again. That produced
        // a 91-minute window backed by only 89 drained minutes — one that
        // existed solely because of the two undrained ones.
        var input = minutes(from: 0, count: 80, ticks: 0)
        for offset in 80..<109 {
            let uncovered = (offset == 89 || offset == 90)
            input += minutes(from: offset, count: 1, ticks: 3,
                             covered: uncovered ? 0 : 60)
        }
        input += minutes(from: 109, count: 200, ticks: 0)

        let lastDrainedBeforeHole = base.addingTimeInterval(89 * 60)
        for window in Core.quiescentWindows(minutes: input) {
            // No window may end inside the undrained pair (minutes 89–90).
            if window.interval.end > lastDrainedBeforeHole {
                XCTAssertGreaterThanOrEqual(
                    window.interval.end, base.addingTimeInterval(91 * 60),
                    "a window must not end on an undrained minute"
                )
            }
            XCTAssertGreaterThanOrEqual(
                window.interval.duration, TimeInterval(90 * 60),
                "and must still clear the floor on drained data alone"
            )
        }
    }

    func testWindowsNeverOverlap() {
        // The reviewer's exact reproducing input: an 11-minute arousal at 6
        // ticks/min put the flanking anchors 21 apart — inside the
        // `(joinGapMinutes, rollingWindowMinutes]` band — so the earlier
        // window's end landed 9 minutes past the later window's start and the
        // shared minutes were reported twice.
        var input = minutes(from: 0, count: 120, ticks: 0)
        input += minutes(from: 120, count: 11, ticks: 6)
        input += minutes(from: 131, count: 270, ticks: 0)

        let windows = Core.quiescentWindows(minutes: input)
        for (earlier, later) in zip(windows, windows.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.interval.end, later.interval.start,
                "windows must not claim the same minute"
            )
        }
        // The documented contract is also an ordering contract.
        XCTAssertEqual(windows.map(\.interval.start),
                       windows.map(\.interval.start).sorted(),
                       "windows must be oldest first")

        // And the reported durations must not exceed the wall-clock span they
        // cover — the arithmetic consequence the reviewer measured (416 min
        // of reported quiet across a 407-minute span).
        if let first = windows.first, let last = windows.last {
            let span = last.interval.end.timeIntervalSince(first.interval.start)
            let summed = windows.reduce(0) { $0 + $1.interval.duration }
            XCTAssertLessThanOrEqual(summed, span)
        }
    }

    func testOverlapFractionUnionsRatherThanDoubleCounting() {
        // Two windows sharing a region must not credit it twice. Built by hand
        // so the helper is tested independently of what the detector emits.
        let quiet = minutes(from: 0, count: 200, ticks: 0)
        guard let single = Core.quiescentWindows(minutes: quiet).first else {
            return XCTFail("expected a window")
        }
        let candidate = DateInterval(start: base, duration: 400 * 60)
        let once = Core.overlapFraction(of: candidate, coveredBy: [single])
        let twice = Core.overlapFraction(of: candidate, coveredBy: [single, single])
        XCTAssertEqual(once, twice, accuracy: 0.0001,
                       "the same window listed twice must not double the credit")
        XCTAssertLessThan(once, 1.0,
                          "a candidate twice the window's length is not fully covered")
    }

    // MARK: - Arousals

    func testAnArousalSplitsIntoTwoAdjacentWindowsRatherThanBeingBridged() {
        // A 6-minute arousal poisons every 30-minute rolling window holding 3+
        // of its minutes, so it costs anchors on both sides and opens a ~34 min
        // anchor gap. The core reports two windows and does NOT bridge them.
        //
        // This is the honest answer, not a limitation to paper over: on the
        // real days every bridging rule chained transitively (see
        // `testMergingAdjacentWindowsIsRejectedBecauseItChains`).
        var night = minutes(from: 0, count: 120, ticks: 0)
        night += minutes(from: 120, count: 6, ticks: 30)   // arousal
        night += minutes(from: 126, count: 150, ticks: 0)
        let windows = Core.quiescentWindows(minutes: night)
        XCTAssertEqual(windows.count, 2,
                       "the arousal is reported as a boundary, not smoothed away")

        // And the two halves must sit close together in wall-clock time, so a
        // caller holding HR can decide for itself that they are one night.
        guard windows.count == 2 else { return }
        let gap = windows[1].interval.start.timeIntervalSince(windows[0].interval.end)
        XCTAssertLessThanOrEqual(gap, 15 * 60,
                                 "an arousal split must leave the halves adjacent")
        for window in windows {
            XCTAssertLessThan(window.meanTicksPerMinute, 0.8,
                              "each half is still squarely in the sleep band")
        }
    }

    func testMergingAdjacentWindowsIsRejectedBecauseItChains() {
        // Why the core does no merging. Three quiet blocks separated by short
        // active spans — the shape of scattered daytime quiescence. Any rule
        // that bridged on wall-clock proximity would fuse all three into one
        // implausible span. Measured on the owner's real days, a 5-minute
        // bridge already produced 8.62 h and a 45-minute bridge 13.65 h.
        var input = minutes(from: 0, count: 120, ticks: 0)
        input += minutes(from: 120, count: 10, ticks: 25)
        input += minutes(from: 130, count: 120, ticks: 0)
        input += minutes(from: 250, count: 10, ticks: 25)
        input += minutes(from: 260, count: 120, ticks: 0)

        let windows = Core.quiescentWindows(minutes: input)
        XCTAssertGreaterThan(windows.count, 1,
                             "the core must not fuse separated quiet blocks")
        let longest = windows.map(\.interval.duration).max() ?? 0
        XCTAssertLessThan(longest, TimeInterval(input.count * 60),
                          "no window may span the whole input")
    }

    func testASustainedActiveBlockDoesSplit() {
        var input = minutes(from: 0, count: 150, ticks: 0)
        input += minutes(from: 150, count: 90, ticks: 40)   // properly awake
        input += minutes(from: 240, count: 150, ticks: 0)
        XCTAssertEqual(Core.quiescentWindows(minutes: input).count, 2)
    }

    // MARK: - Duration floor

    func testShortQuietSpansAreNotReportedAsSleep() {
        XCTAssertTrue(Core.quiescentWindows(minutes: minutes(from: 0, count: 45, ticks: 0)).isEmpty)
    }

    // MARK: - Reported features match the measured bands

    func testLongestQuietRunLandsInTheConfirmedSleepBand() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        guard let window = windows.first else { return XCTFail("expected a window") }
        // Confirmed sleeps ran 87–193 min; sedentary wake never passed 56.
        XCTAssertGreaterThan(window.longestQuietRunMinutes, 56)
    }

    func testCoverageFractionIsReportedNotEnforced() {
        // A hole small enough that the rolling window still clears its coverage
        // floor stays inside one window — and is disclosed, not hidden.
        var input = minutes(from: 0, count: 120, ticks: 0)
        input += minutes(from: 125, count: 130, ticks: 0)   // 5-minute hole
        let windows = Core.quiescentWindows(minutes: input)
        XCTAssertEqual(windows.count, 1)
        guard let window = windows.first else { return }
        XCTAssertLessThan(window.coverageFraction, 1.0,
                          "the hole must be visible in the reported coverage")
        XCTAssertGreaterThan(window.coverageFraction, 0.9)
    }

    func testAHoleWideEnoughToBreakAnchorsSplitsIntoFullyCoveredWindows() {
        // The counterpart, and the stronger honesty property: once a hole is
        // wide enough to starve the rolling window's coverage floor, the result
        // is two windows that each stop at real data — NOT one window spanning
        // undrained time at a quietly degraded coverage fraction.
        var input = minutes(from: 0, count: 120, ticks: 0)
        input += minutes(from: 130, count: 130, ticks: 0)   // 10-minute hole
        let windows = Core.quiescentWindows(minutes: input)
        XCTAssertEqual(windows.count, 2)
        for window in windows {
            XCTAssertEqual(window.coverageFraction, 1.0, accuracy: 0.0001,
                           "each window must be backed by rows end to end")
        }
        // And neither may reach into the hole.
        guard windows.count == 2 else { return }
        XCTAssertLessThanOrEqual(windows[0].interval.end,
                                 base.addingTimeInterval(120 * 60))
        XCTAssertGreaterThanOrEqual(windows[1].interval.start,
                                    base.addingTimeInterval(130 * 60))
    }

    // MARK: - Parameter insensitivity is the evidence

    func testTheRuleIsInsensitiveToItsOwnConstants() {
        // Across the sweep that scored the real days, recall moved 78%→79% and
        // false positives on workouts stayed at 0. A rule that only works at
        // one setting is a fit, not a finding — so assert the neighbourhood.
        //
        // The invariant is that an uninterrupted sleep-rate block reads as ONE
        // window everywhere in the neighbourhood. Window *count* on interrupted
        // input is deliberately not invariant: a wider rolling window costs
        // more anchors around an arousal, which is the behaviour pinned by
        // `testAnArousalSplitsIntoTwoAdjacentWindowsRatherThanBeingBridged`.
        let night = minutes(from: 0, count: 400, ticks: 0)

        for window in [20, 30, 45] {
            for quiet in [1.5, 2.0, 3.0] {
                for join in [15, 20, 30] {
                    var parameters = Core.Parameters.measured
                    parameters.rollingWindowMinutes = window
                    parameters.quietTicksPerMinute = quiet
                    parameters.joinGapMinutes = join
                    let result = Core.quiescentWindows(minutes: night, parameters: parameters)
                    XCTAssertEqual(result.count, 1,
                                   "w=\(window) q=\(quiet) j=\(join) must still see one night")
                }
            }
        }
    }

    func testSedentaryStaysRejectedAcrossTheSameNeighbourhood() {
        let sedentary = minutes(from: 0, count: 480, ticks: 10)
        for window in [20, 30, 45] {
            for quiet in [1.5, 2.0, 3.0] {
                var parameters = Core.Parameters.measured
                parameters.rollingWindowMinutes = window
                parameters.quietTicksPerMinute = quiet
                XCTAssertTrue(
                    Core.quiescentWindows(minutes: sedentary, parameters: parameters).isEmpty,
                    "w=\(window) q=\(quiet) must not admit sedentary wake"
                )
            }
        }
    }

    // MARK: - Corroboration helper

    func testOverlapFractionMeasuresTheCandidatesOwnMinutes() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        let candidate = DateInterval(start: base, duration: 240 * 60)
        XCTAssertGreaterThan(Core.overlapFraction(of: candidate, coveredBy: windows), 0.9)

        let elsewhere = DateInterval(start: base.addingTimeInterval(86_400), duration: 3_600)
        XCTAssertEqual(Core.overlapFraction(of: elsewhere, coveredBy: windows), 0)
    }

    func testOverlapFractionIsBoundedAndSafeOnDegenerateInput() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        XCTAssertEqual(
            Core.overlapFraction(of: DateInterval(start: base, duration: 0),
                                 coveredBy: windows),
            0
        )
        XCTAssertLessThanOrEqual(
            Core.overlapFraction(of: DateInterval(start: base, duration: 60),
                                 coveredBy: windows + windows),
            1
        )
    }

    // MARK: - Which windows the confirmed record does not explain

    private func confirmed(_ fromMinute: Int, _ toMinute: Int) -> DateInterval {
        DateInterval(start: base.addingTimeInterval(TimeInterval(fromMinute * 60)),
                     end: base.addingTimeInterval(TimeInterval(toMinute * 60)))
    }

    func testAWindowTheUserAlreadyConfirmedIsNotNews() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        XCTAssertTrue(
            Core.unexplainedWindows(windows, explainedBy: [confirmed(0, 240)]).isEmpty
        )
    }

    func testAQuietWindowWithNoConfirmedSleepIsSurfaced() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        // A confirmed sleep on a completely different day explains nothing.
        let elsewhere = confirmed(2_000, 2_200)
        XCTAssertEqual(
            Core.unexplainedWindows(windows, explainedBy: [elsewhere]).count, 1
        )
    }

    func testAnEmptyConfirmedRecordExplainsNothing() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        XCTAssertEqual(Core.unexplainedWindows(windows, explainedBy: []).count,
                       windows.count)
    }

    func testABriefConfirmedNapDoesNotSuppressALongQuietBlock() {
        // The 08-24 shape: a short confirmed sleep near a long quiet window.
        // Suppressing the block because its edge overlaps a nap is exactly how
        // a 6.53 h sleep goes unreported.
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 400, ticks: 0))
        guard let window = windows.first else { return XCTFail("expected a window") }
        let nap = confirmed(0, 60)   // 60 min against a ~400 min block
        XCTAssertEqual(
            Core.unexplainedWindows([window], explainedBy: [nap]).count, 1,
            "a small overlap must not mark a long block as accounted for"
        )
    }

    func testOverlappingConfirmedSleepsCountTheirSharedTimeOnce() {
        // Two heavily overlapping confirmed records must not sum past the
        // window and mark it explained when it is not.
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 400, ticks: 0))
        guard let window = windows.first else { return XCTFail("expected a window") }
        let a = confirmed(0, 120)
        let b = confirmed(10, 130)   // overlaps `a` almost entirely
        XCTAssertEqual(
            Core.unexplainedWindows([window], explainedBy: [a, b]).count, 1,
            "double-counted overlap would wrongly explain the window away"
        )
    }

    func testAMostlyConfirmedWindowIsTreatedAsAccountedFor() {
        let windows = Core.quiescentWindows(minutes: minutes(from: 0, count: 240, ticks: 0))
        guard let window = windows.first else { return XCTFail("expected a window") }
        let most = confirmed(0, 200)   // > 50% of the ~240 min window
        XCTAssertTrue(Core.unexplainedWindows([window], explainedBy: [most]).isEmpty)
    }

    // MARK: - Telling a real all-nighter from a missed sleep

    private func cycle(_ fromMinute: Int, _ toMinute: Int) -> DateInterval {
        DateInterval(start: base.addingTimeInterval(TimeInterval(fromMinute * 60)),
                     end: base.addingTimeInterval(TimeInterval(toMinute * 60)))
    }

    func testAGenuineNightAwakeIsSupportedByTheWrist() {
        // Sedentary-awake tick rates for a whole cycle: the record says no
        // sleep and the wrist agrees.
        let awake = minutes(from: 0, count: 600, ticks: 10)
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 600), minutes: awake),
            .supported
        )
    }

    func testAMissedSleepContradictsTheNoSleepRecord() {
        // The 2026-08-24 shape: active, then a long quiet block nobody
        // confirmed, then active again.
        var input = minutes(from: 0, count: 200, ticks: 10)
        input += minutes(from: 200, count: 240, ticks: 0)
        input += minutes(from: 440, count: 160, ticks: 10)

        switch Core.assessNoSleepCycle(cycle(0, 600), minutes: input) {
        case .contradicted(let longest):
            XCTAssertGreaterThan(longest.interval.duration, 3 * 3_600,
                                 "the missed block must be reported at its real length")
            XCTAssertLessThan(longest.meanTicksPerMinute, 0.8)
        default:
            XCTFail("a 4-hour quiet block must contradict a no-sleep record")
        }
    }

    func testAConfirmedSleepInsideTheCycleDoesNotCountAsAContradiction() {
        // If the user already told us about it, motion has nothing to add.
        var input = minutes(from: 0, count: 200, ticks: 10)
        input += minutes(from: 200, count: 240, ticks: 0)
        input += minutes(from: 440, count: 160, ticks: 10)
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 600),
                                    minutes: input,
                                    confirmedSleeps: [confirmed(200, 440)]),
            .supported
        )
    }

    func testAnUndrainedCycleIsUnverifiableRatherThanSupported() {
        // The failure this exists to prevent: turning missing history into a
        // confirmed all-nighter. Absent evidence is not evidence.
        let sparse = minutes(from: 0, count: 100, ticks: 10)   // 100 of 600 min
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 600), minutes: sparse),
            .unverifiable
        )
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 600), minutes: []),
            .unverifiable
        )
    }

    func testAZeroLengthCycleCannotBeAssessed() {
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 0),
                                    minutes: minutes(from: 0, count: 600, ticks: 10)),
            .unverifiable
        )
    }

    func testMotionOutsideTheCycleIsIgnored() {
        // A quiet block belonging to a neighbouring day must not contradict
        // this cycle's record.
        var input = minutes(from: 0, count: 600, ticks: 10)
        input += minutes(from: 700, count: 300, ticks: 0)
        XCTAssertEqual(
            Core.assessNoSleepCycle(cycle(0, 600), minutes: input),
            .supported
        )
    }

    func testNoInputProducesNoWindows() {
        XCTAssertTrue(Core.quiescentWindows(minutes: []).isEmpty)
    }

    // MARK: - Bounded stop

    func testTheCoreIsWiredOnlyThroughTheReviewOnlyDetector() throws {
        // WIRED DELIBERATELY, 2026-08-28. This test previously pinned the core
        // as unwired, its comment requiring "a decision to ship it". That
        // decision is the owner's active goal, verbatim: "it did not detect my
        // sleep (i sleep during day time)", "no review cards", "can we do more
        // breakthrough in detections". Two consecutive measured daytime sleeps
        // (0.73 and 1.40 ticks/min vs 12-20 awake) had an EMPTY candidate
        // pool; the wiring is REVIEW-ONLY through the pending-review card and
        // was adversarially reviewed before shipping (hard HR presence +
        // depression gates, observed-quiet-only duration, single-slot
        // precedence).
        //
        // The pin's spirit survives: the core may be referenced ONLY by the
        // detector that carries those gates — anything else re-opens the
        // silent-wiring hazard this test existed to stop.
        let allowed: Set<String> = [
            "AtriaSleepMotionQuiescence.swift",
            "AtriaDaytimeQuiescentSleepDetector.swift",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .filter { !allowed.contains($0.lastPathComponent) }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(
                source.contains("AtriaSleepMotionQuiescence"),
                "\(file.lastPathComponent) references the core outside the "
                    + "review-only detector"
            )
        }
    }
}
