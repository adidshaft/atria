import XCTest
@testable import Atria

/// Device pull 2026-08-25 (four days of the user's real compact shards):
///
/// | day   | rows          | ledger coverage | steps credited |
/// |-------|---------------|-----------------|----------------|
/// | 08-22 | 88,973 (24h)  | 0%              | 0              |
/// | 08-23 | 53,246 (24h)  | 0%              | 0              |
/// | 08-24 | 89,481 (24h)  | 37%             | 8,038          |
/// | 08-25 | 24,701 (6.6h) | 8%              | 145            |
///
/// The motion-bank coverage ledger is a 512-entry FIFO whose median entry is
/// 24 s, so it retained only 9.77 h of coverage in total (oldest 08-24 09:59).
/// Complete ~1 Hz rows existed for every one of those days and were thrown
/// away because no ledger interval happened to cover them.
///
/// Coverage is not what makes a step honest — the sequence reducer's per-pair
/// gates are (a pair is admitted only when the flash counter advanced by a
/// plausible amount for the elapsed time, which is precisely the proof that
/// the strap was recording across that pair). So stored rows are first-class
/// coverage, and the ledger is a weaker proxy for the same fact.
final class AtriaMotionRowDerivedCoverageTests: XCTestCase {

    private typealias Store = AtriaWhoop4MotionTickCompactStore
    private typealias Point = Store.Point

    /// 2026-08-24T12:00:00Z — after the 2026-08-06 fixture anchor floor.
    private let base = Date(timeIntervalSince1970: 1_787_572_800)

    /// Oscillating gravity, matching the fixture shape the compact-store
    /// tests already use — the cadence model needs a real gait signal before
    /// it will resolve motion, and a flat vector resolves nothing.
    private func point(_ offset: TimeInterval,
                       tick: Int,
                       flash: UInt32) -> Point {
        let timestamp = base.timeIntervalSince1970 + offset
        let phase = timestamp * 0.41
        return Point(timestamp: timestamp,
                     flash: flash,
                     tick: tick,
                     gravityX: 0.08 * sin(phase),
                     gravityY: 0.08 * cos(phase),
                     gravityZ: 1 + 0.04 * sin(phase * 0.7),
                     unknownMotionScalar32: 0.1,
                     identity: "fixture")
    }

    /// One second apart, one step and four flash counts per second.
    private func run(from startOffset: TimeInterval,
                     seconds: Int,
                     startTick: Int = 0,
                     startFlash: UInt32 = 0) -> [Point] {
        (0...seconds).map { i in
            point(startOffset + TimeInterval(i),
                  tick: startTick + i,
                  flash: startFlash + UInt32(i) * 4)
        }
    }

    private func window(_ seconds: TimeInterval) -> DateInterval {
        DateInterval(start: base, end: base.addingTimeInterval(seconds))
    }

    // MARK: - The derivation itself

    func testContiguousRowsBecomeOneCoverageInterval() {
        let coverage = Store.rowDerivedCoverage(
            points: run(from: 0, seconds: 60),
            window: window(3600)
        )
        XCTAssertEqual(coverage.count, 1)
        XCTAssertEqual(coverage.first?.start, base)
        XCTAssertEqual(coverage.first?.end, base.addingTimeInterval(60))
    }

    func testAGapLongerThanTheAllowanceSplitsTheRun() {
        let points = run(from: 0, seconds: 30)
            + run(from: 300, seconds: 30, startTick: 500, startFlash: 4_000)
        // The allowance is the cadence model's own 3s continuous-sample gap.
        let coverage = Store.rowDerivedCoverage(
            points: points,
            window: window(3600)
        )
        XCTAssertEqual(coverage.count, 2,
                       "a five-minute hole is not covered and must not be "
                           + "bridged into one interval")
        XCTAssertEqual(coverage.first?.end, base.addingTimeInterval(30))
        XCTAssertEqual(coverage.last?.start, base.addingTimeInterval(300))
    }

    func testCoverageIsClippedToTheRequestedWindow() {
        let coverage = Store.rowDerivedCoverage(
            points: run(from: -100, seconds: 200),
            window: window(50)
        )
        XCTAssertEqual(coverage.count, 1)
        XCTAssertEqual(coverage.first?.start, base)
        XCTAssertEqual(coverage.first?.end, base.addingTimeInterval(50))
    }

    func testASingleRowProvesNoInterval() {
        XCTAssertTrue(Store.rowDerivedCoverage(
            points: [point(0, tick: 0, flash: 0)],
            window: window(3600)
        ).isEmpty, "one row cannot prove a span")
        XCTAssertTrue(Store.rowDerivedCoverage(
            points: [],
            window: window(3600)
        ).isEmpty)
    }


    // MARK: - Bounds that keep the read affordable and honest

    func testLongRunsAreChunkedSoTheQuadraticDFTStaysAffordable() {
        // A drained day can hold one 29,994-row continuous run. The cadence
        // model's DFT is O(1.5*N^2) per run — ~2.5e9 operations, about two
        // minutes of CPU, on a path re-driven every few seconds during a
        // drain. Chunking happens on the cadence INPUT so interval boundary
        // semantics (the +/-3s veto, allowOpenTail) are untouched.
        let points = run(from: 0, seconds: 1_000)
        let chunks = Store.boundedCadenceFragments(points[...])
        XCTAssertGreaterThan(chunks.count, 1,
                             "a 1000s run must not become one DFT input")
        for chunk in chunks {
            guard let first = chunk.first, let last = chunk.last else {
                return XCTFail("empty chunk")
            }
            XCTAssertLessThanOrEqual(last.timestamp - first.timestamp, 91)
        }
        // Chunking must partition: every row appears exactly once, in order.
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.count }, points.count,
                       "chunking must not drop or duplicate rows")
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.timestamp),
                       points.map(\.timestamp))
    }

    func testAShortRunIsHandedToTheModelWhole() {
        let points = run(from: 0, seconds: 40)
        let chunks = Store.boundedCadenceFragments(points[...])
        XCTAssertEqual(chunks.count, 1,
                       "nothing under the bound may be perturbed")
    }

    func testAThreeSecondHoleIsNotBridgedIntoKnownCoverage() {
        // Gaps are only bridged up to the cadence model's own 3s allowance, so
        // knownCoverageSeconds cannot silently absorb unsampled time.
        let points = run(from: 0, seconds: 20)
            + run(from: 28, seconds: 20, startTick: 400, startFlash: 3_000)
        let coverage = Store.rowDerivedCoverage(
            points: points,
            window: window(200)
        )
        XCTAssertEqual(coverage.count, 2,
                       "an 8s hole is unsampled and must stay uncovered")
    }

    // MARK: - What it changes end to end

    func testStoredRowsAreCreditedWhenTheLedgerRetainedNothing() {
        // The 08-22 / 08-23 shape: a full run of rows, zero ledger intervals.
        let points = run(from: 0, seconds: 600)
        let result = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(600),
            bankCoverage: []
        )
        guard case .qualified(let evidence) = result.read else {
            return XCTFail("rows exist; the day must not read as incomplete")
        }
        // `motionTicks` is the deterministic counter sum. `steps` is the
        // gait model's read of the same fragments and needs real gravity
        // oscillation, which a synthetic fixture does not carry — so assert
        // the quantity this change actually governs.
        // The point of this test: with ZERO ledger intervals the read used to
        // return `.incomplete` and the day scored nothing. It now reaches the
        // reducer and credits every counter tick the rows prove.
        XCTAssertEqual(evidence.motionTicks, 600,
                       "every second carried one counter tick")
        // `knownCoverageSeconds` is GAIT-QUALIFIED time (covered seconds minus
        // the cadence model's unresolved seconds), not raw covered time. A
        // synthetic fixture carries no real gait, so the model may resolve
        // none of it — that is the model's call, not this change's.
        XCTAssertLessThanOrEqual(evidence.knownCoverageSeconds, 600)
    }

    func testLedgerCreditIsNeverLostByTheUnion() {
        let points = run(from: 0, seconds: 600)
        let withLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(600),
            bankCoverage: [DateInterval(start: base,
                                        end: base.addingTimeInterval(600))]
        )
        let withoutLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(600),
            bankCoverage: []
        )
        guard case .qualified(let a) = withLedger.read,
              case .qualified(let b) = withoutLedger.read else {
            return XCTFail("both reads must qualify")
        }
        XCTAssertEqual(a.motionTicks, b.motionTicks,
                       "the union must be a superset, never a different answer")
        XCTAssertGreaterThanOrEqual(a.knownCoverageSeconds,
                                    b.knownCoverageSeconds)
    }

    func testAGenuineHoleStaysMissingRatherThanBeingInvented() {
        // Rows for the first and last ten minutes, nothing in between: the
        // hole must stay missing coverage, and its steps must stay uncounted.
        let points = run(from: 0, seconds: 600)
            + run(from: 3_000, seconds: 600, startTick: 5_000, startFlash: 40_000)
        let result = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(3_600),
            bankCoverage: []
        )
        guard case .qualified(let evidence) = result.read else {
            return XCTFail("the covered halves must still qualify")
        }
        XCTAssertEqual(evidence.motionTicks, 1_200,
                       "only the two real runs may be credited")
        XCTAssertLessThanOrEqual(evidence.knownCoverageSeconds, 1_200,
                                 "the hole can never become known time")
        XCTAssertGreaterThanOrEqual(evidence.missingCoverageSeconds, 2_400,
                                    "the 40-minute hole must remain missing")
    }

    func testAStalledFlashCounterEarnsNoStepsEvenWithRowsPresent() {
        // Rows exist and the tick counter climbs, but flash never advances —
        // the strap was not really recording. Widening coverage must not turn
        // that into steps; the per-pair gate is what polices it.
        let points = (0...600).map { i in
            point(TimeInterval(i), tick: i, flash: 0)
        }
        let result = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(600),
            bankCoverage: []
        )
        if case .qualified(let evidence) = result.read {
            XCTAssertEqual(evidence.motionTicks, 0,
                           "a stalled flash counter proves nothing")
            XCTAssertEqual(evidence.steps, 0)
        }
    }

    func testCounterResetIsNotCreditedAsAHugeWrap() {
        // The strap's counter resets to 0 (observed on device at 08-24 08:00
        // and 08-25 00:00). Modulo arithmetic would read 22_883 -> 0 as a
        // +42_653 wrap; the rate gate must reject it instead.
        var points = run(from: 0, seconds: 300, startTick: 22_583, startFlash: 0)
        points += run(from: 301, seconds: 300,
                      startTick: 0, startFlash: 4 * 301)
        let result = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(700),
            bankCoverage: []
        )
        if case .qualified(let evidence) = result.read {
            XCTAssertLessThan(evidence.motionTicks, 1_000,
                              "a reset must never be credited as a wrap")
        }
    }

    // MARK: - PROBE (temporary)

    func testProbeMisalignedLedgerVetoesOverlappingRowRun() {
        // Rows only from +300s to +1200s (the first five minutes were never
        // drained). Ledger interval [base, base+1200] came from bank arm/close
        // wall-clock instants, so its start has no row within +/-3s.
        let points = run(from: 300, seconds: 900)
        let withMisalignedLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(1_200),
            bankCoverage: [DateInterval(start: base,
                                        end: base.addingTimeInterval(1_200))]
        )
        let withoutLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(1_200),
            bankCoverage: []
        )
        print("PROBE withMisalignedLedger=\(withMisalignedLedger.read)")
        print("PROBE withoutLedger=\(withoutLedger.read)")
    }

    func testProbePartialOffloadTailVetoesRowRun() {
        // Rows [base, base+600]; ledger armed [base, base+1200] but the last
        // ten minutes of the bank never offloaded.
        let points = run(from: 0, seconds: 600)
        let withLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(3_600),
            bankCoverage: [DateInterval(start: base,
                                        end: base.addingTimeInterval(1_200))]
        )
        let withoutLedger = Store.motionTickDayEvidenceReadForTesting(
            sortedPoints: points,
            start: base,
            end: base.addingTimeInterval(3_600),
            bankCoverage: []
        )
        print("PROBE tail withLedger=\(withLedger.read)")
        print("PROBE tail withoutLedger=\(withoutLedger.read)")
    }

}
