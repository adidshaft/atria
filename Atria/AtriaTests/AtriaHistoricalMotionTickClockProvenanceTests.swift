import XCTest
@testable import Atria

final class AtriaHistoricalMotionTickClockProvenanceTests: XCTestCase {
    typealias Provenance = HistoricalArchive.MotionTickPayloadClockProvenance
    typealias Resolution = HistoricalArchive.MotionTickPayloadClockResolution

    func testEarlierObservationReplacesLaterReplayClockTuple() {
        let later = Provenance(
            observedAtUnix: 200,
            endpointTimestamp: 1_000,
            clockDeviceRef: 700,
            clockWallRef: 1_000,
            clockOffsetSeconds: 300
        )
        let earlier = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 900,
            clockWallRef: 900,
            clockOffsetSeconds: 0
        )

        let selected = HistoricalArchive.resolveMotionTickPayloadClockProvenance(
            existing: .accepted(later),
            candidate: earlier
        )

        XCTAssertEqual(selected, .accepted(earlier))
    }

    func testLaterDuplicateCannotOverwriteEarliestEndpointOrDrift() {
        let earliest = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 900,
            clockWallRef: 900,
            clockOffsetSeconds: 0
        )
        let later = Provenance(
            observedAtUnix: 200,
            endpointTimestamp: 1_200,
            clockDeviceRef: 900,
            clockWallRef: 1_200,
            clockOffsetSeconds: 300
        )

        let selected = HistoricalArchive.resolveMotionTickPayloadClockProvenance(
            existing: .accepted(earliest),
            candidate: later
        )

        XCTAssertEqual(selected, .accepted(earliest))
    }

    func testEqualObservationWithConflictingClockTupleFailsClosed() {
        let first = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 900,
            clockWallRef: 900,
            clockOffsetSeconds: 0
        )
        let conflict = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 600,
            clockWallRef: 600,
            clockOffsetSeconds: 0
        )

        let selected = HistoricalArchive.resolveMotionTickPayloadClockProvenance(
            existing: .accepted(first),
            candidate: conflict
        )

        XCTAssertEqual(
            selected,
            .conflicted(earliestObservedAtUnix: first.observedAtUnix)
        )
    }

    func testIdenticalDuplicateRetainsOneAcceptedPayload() {
        let first = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 900,
            clockWallRef: 900,
            clockOffsetSeconds: 0
        )

        let selected = HistoricalArchive.resolveMotionTickPayloadClockProvenance(
            existing: .accepted(first),
            candidate: first
        )

        XCTAssertEqual(selected, .accepted(first))
    }

    func testEarlierObservationCanResolveConflictSeenLaterInScanOrder() {
        let conflicted = Resolution.conflicted(earliestObservedAtUnix: 200)
        let earlier = Provenance(
            observedAtUnix: 100,
            endpointTimestamp: 900,
            clockDeviceRef: 900,
            clockWallRef: 900,
            clockOffsetSeconds: 0
        )

        let selected = HistoricalArchive.resolveMotionTickPayloadClockProvenance(
            existing: conflicted,
            candidate: earlier
        )

        XCTAssertEqual(selected, .accepted(earlier))
    }

    func testDailyEvidenceUsesOneClockResolutionForRowsAndOffsetSupport() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/HistoricalArchive.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "static func motionTickDayEvidence("))
        let end = try XCTUnwrap(
            source.range(
                of: "private static func mergedMotionCoverage(",
                range: start.upperBound..<source.endIndex
            )
        )
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains(
            "resolveMotionTickPayloadClockProvenance("
        ))
        XCTAssertTrue(body.contains(
            "clockResolutionByPayload[payloadHex] = resolution"
        ))
        XCTAssertTrue(body.contains("rows.removeValue(forKey: payloadHex)"))
        XCTAssertTrue(body.contains(
            "clockOffsetByPayload.removeValue(forKey: payloadHex)"
        ))
        XCTAssertTrue(body.contains(
            "clockOffsetByPayload[payloadHex] = accepted.clockOffsetSeconds"
        ))
        XCTAssertFalse(body.contains(
            "clockOffsetByPayload[payloadHex] = drift"
        ))
    }
}
