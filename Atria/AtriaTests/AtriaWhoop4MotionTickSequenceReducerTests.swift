import XCTest
@testable import Atria

final class AtriaWhoop4MotionTickSequenceReducerTests: XCTestCase {
    func testSequentialWalkAndExactDuplicateAreCountedOnce() {
        let points = [
            point(0, tick: 1_000, flash: 10, id: "a"),
            point(1, tick: 1_010, flash: 11, id: "b"),
            point(1, tick: 1_010, flash: 11, id: "b-copy"),
            point(2, tick: 1_020, flash: 12, id: "c"),
        ]
        let result = reduce(points, end: 2)
        XCTAssertEqual(result?.ticks, 20)
        XCTAssertEqual(result?.knownDuration, 2)
        XCTAssertEqual(result?.admittedRows, 3)
    }

    func testSameTimestampConflictFailsClosed() {
        let points = [
            point(0, tick: 1_000, flash: 10, id: "a"),
            point(1, tick: 1_010, flash: 11, id: "b"),
            point(1, tick: 1_011, flash: 11, id: "conflict"),
            point(2, tick: 1_020, flash: 12, id: "c"),
        ]
        XCTAssertNil(reduce(points, end: 2))
    }

    func testSingleUInt16WrapIsAdmittedWhenRateIsPlausible() {
        let points = [
            point(0, tick: 65_530, flash: 100, id: "a"),
            point(1, tick: 4, flash: 101, id: "b"),
        ]
        XCTAssertEqual(reduce(points, end: 1)?.ticks, 10)
    }

    func testImplausibleModuloJumpIsRejected() {
        let points = [
            point(0, tick: 65_000, flash: 100, id: "a"),
            point(1, tick: 1_000, flash: 101, id: "b"),
        ]
        XCTAssertNil(reduce(points, end: 1))
    }

    func testIntervalLongEnoughToHideFullRevolutionIsRejected() {
        let points = [
            point(0, tick: 1_000, flash: 100, id: "a"),
            point(5_500, tick: 1_001, flash: 101, id: "b"),
        ]
        XCTAssertNil(reduce(points, end: 5_500))
    }

    func testFlashRegressionWithoutUInt32WrapIsRejected() {
        let points = [
            point(0, tick: 1_000, flash: 100, id: "a"),
            point(1, tick: 1_005, flash: 50, id: "b"),
        ]
        XCTAssertNil(reduce(points, end: 1))
    }

    private func reduce(
        _ points: [AtriaWhoop4MotionTickSequenceReducer.Point],
        end: TimeInterval
    ) -> AtriaWhoop4MotionTickSequenceReducer.Result? {
        AtriaWhoop4MotionTickSequenceReducer.reduce(
            points: points,
            intervals: [
                .init(
                    start: Date(timeIntervalSince1970: 0),
                    end: Date(timeIntervalSince1970: end)
                ),
            ],
            boundaryTolerance: 0
        )
    }

    private func point(
        _ timestamp: TimeInterval,
        tick: Int,
        flash: UInt32,
        id: String
    ) -> AtriaWhoop4MotionTickSequenceReducer.Point {
        .init(timestamp: timestamp, tick: tick, flash: flash, identity: id)
    }
}
