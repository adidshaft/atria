import XCTest
@testable import Atria

/// P6 (2026-08-20 sleep-stage design 2.1/2.2) — the pure `stageAtDate` join
/// that colors the overnight HR trace's observed 5-minute buckets from the
/// hypnogram's display stage runs, and the legend's estimate-title co-render.
///
/// The join is pure wall-clock Date containment: a bucket inside a run takes
/// that run's display stage; a bucket outside every run is nil (unscored gap,
/// neutral style); containment is half-open [start, end) so exactly-abutting
/// runs hand a boundary to exactly one owner and NOTHING is ever bridged.
final class AtriaSleepStressStageColorTests: XCTestCase {
    private typealias Run = AtriaSleepHypnogramPresentation.Run

    /// 2026-08-13 22:00:00 UTC — post-2026-08-06 fixture time base.
    private let base = Date(timeIntervalSince1970: 1_786_658_400)

    private func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    private func run(_ stage: SleepStageKind,
                     from: Double,
                     to: Double) -> Run {
        Run(stage: stage, start: at(from), end: at(to), isComposite: false)
    }

    // MARK: - stageAtDate join

    func testBucketInsideRunTakesThatRunsStage() {
        let runs = [run(.light, from: 0, to: 60),
                    run(.rem, from: 60, to: 120)]

        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(30), runs: runs), .light)
        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(90), runs: runs), .rem)
        // A run's exact start is inside it.
        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(0), runs: runs), .light)
        // Half-open handoff: the shared boundary of two exactly-abutting runs
        // belongs to exactly one owner — the later run.
        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(60), runs: runs), .rem)
    }

    func testJoinIsOrderIndependentAndFoldsSWSToDeep() {
        // Runs are non-overlapping by construction; feeding them out of order
        // must not change the containment answer.
        let shuffled = [run(.rem, from: 60, to: 120),
                        run(.light, from: 0, to: 60)]
        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(30), runs: shuffled), .light)

        // Defensive display fold: a run carrying the engine's `.sws` band
        // colors as Deep, matching every other display surface.
        let sws = [run(.sws, from: 0, to: 30)]
        XCTAssertEqual(AtriaSleepStressStageColoring.stageAtDate(at(10), runs: sws), .deep)
    }

    func testBucketInGapBetweenRunsIsNil() {
        // 30-minute unscored hole between the runs: buckets there stay
        // neutral — the join never assigns a stage the timeline did not draw.
        let runs = [run(.light, from: 0, to: 30),
                    run(.deep, from: 60, to: 90)]

        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(at(45), runs: runs))
        // 1 second past a run's end is already outside it.
        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(
            at(30).addingTimeInterval(1), runs: runs))
    }

    func testNoBridgingBeyondRunEdges() {
        let runs = [run(.light, from: 0, to: 30),
                    run(.deep, from: 60, to: 90)]

        // Before the first run and after the last run: nil, never the nearest
        // stage.
        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(at(-5), runs: runs))
        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(at(95), runs: runs))
        // End-exclusive: the final run never claims the bucket at its own
        // wall-clock end.
        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(at(90), runs: runs))
        // No runs at all: every bucket stays neutral.
        XCTAssertNil(AtriaSleepStressStageColoring.stageAtDate(at(30), runs: []))
    }

    // MARK: - Legend

    func testLegendStagesFollowDisplayOrderAndFoldSWS() {
        // Present stages only, in the canonical [awake, light, rem, deep]
        // display order regardless of run order; `.sws` folds into Deep and
        // never becomes a fifth legend entry.
        let runs = [run(.deep, from: 60, to: 90),
                    run(.awake, from: 0, to: 10),
                    run(.sws, from: 90, to: 120)]

        XCTAssertEqual(AtriaSleepStressStageColoring.legendStages(for: runs),
                       [.awake, .deep])
        XCTAssertEqual(AtriaSleepStressStageColoring.legendStages(for: []), [])
    }

    func testEstimateLegendCoRendersMandatoryEstimateTitle() {
        let runs = [run(.light, from: 0, to: 60),
                    run(.rem, from: 60, to: 120)]

        // Estimate night: the legend string carries the full mandatory title
        // ("Estimated stages · HR-only") appended as "· Estimated stages …" —
        // the honesty label travels with the stage-derived pixels (2.0).
        let estimated = AtriaSleepStressStageColoring.legendText(runs: runs,
                                                                 isEstimated: true)
        XCTAssertNotNil(estimated)
        XCTAssertTrue(estimated?.contains(AtriaSleepStageEstimateLabel.title) == true)
        XCTAssertTrue(estimated?.contains("· Estimated stages") == true)
        XCTAssertEqual(estimated,
                       "Light · REM · \(AtriaSleepStageEstimateLabel.title)")

        // Validated night: stage names only, no estimate marker.
        let validated = AtriaSleepStressStageColoring.legendText(runs: runs,
                                                                 isEstimated: false)
        XCTAssertEqual(validated, "Light · REM")
        XCTAssertFalse(validated?.contains(AtriaSleepStageEstimateLabel.title) == true)
    }

    func testNoRunsMeansNoLegendEvenWhenEstimated() {
        // No stage pixels ⇒ no legend, and no estimate marker with nothing to
        // qualify — the marker must never imply stages that were not drawn.
        XCTAssertNil(AtriaSleepStressStageColoring.legendText(runs: [],
                                                              isEstimated: true))
        XCTAssertNil(AtriaSleepStressStageColoring.legendText(runs: [],
                                                              isEstimated: false))
    }
}
