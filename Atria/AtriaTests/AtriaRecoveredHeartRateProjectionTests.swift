import XCTest
@testable import Atria

final class AtriaRecoveredHeartRateProjectionTests: XCTestCase {
    private let configuration = AtriaRecoveredHeartRateProjection.Configuration(
        maximumGap: 10,
        expectedSampleInterval: 1
    )

    func testDisconnectGapCreatesExactNonInterpolatedWindowsAndCoverage() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000.125)
        let points = [
            point(start, 0, 60),
            point(start, 1, 61),
            point(start, 2, 62),
            point(start, 120, 70),
            point(start, 121, 71),
        ]

        let result = AtriaRecoveredHeartRateProjection.project(
            historical: points,
            configuration: configuration
        )

        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows.map { $0.samples.count }, [3, 2])
        XCTAssertEqual(result.samples.map(\.timestamp), points.map(\.t))
        XCTAssertEqual(result.samples.map(\.bpm), [60, 61, 62, 70, 71])
        XCTAssertTrue(result.samples.allSatisfy { $0.source == .historicalArchive })

        let coverage = result.statistics.coverage
        XCTAssertEqual(coverage.timelineSpanSeconds, 121, accuracy: 0.000_001)
        XCTAssertEqual(coverage.coveredSeconds, 3, accuracy: 0.000_001)
        XCTAssertEqual(coverage.uncoveredSeconds, 118, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(coverage.coverageFraction), 3.0 / 121.0,
                       accuracy: 0.000_001)
        XCTAssertEqual(coverage.maximumObservedGapSeconds, 118)
        XCTAssertEqual(coverage.splitGapCount, 1)
        XCTAssertEqual(result.windows[0].coverage.coverageFraction, 1)
        XCTAssertEqual(result.windows[1].coverage.coverageFraction, 1)
    }

    func testArchiveReplayIsIdempotentAndOrderingIndependent() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let a = point(start, 0, 60)
        let b = point(start, 1, 61)
        let c = point(start, 2, 62)

        let original = AtriaRecoveredHeartRateProjection.project(
            historical: [a, b, c],
            configuration: configuration
        )
        let replayed = AtriaRecoveredHeartRateProjection.project(
            historical: [c, a, b, b, a, c],
            configuration: configuration
        )

        XCTAssertEqual(replayed.windows, original.windows)
        XCTAssertEqual(replayed.samples.map(\.stableKey), original.samples.map(\.stableKey))
        XCTAssertEqual(replayed.statistics.duplicateTimestampCount, 3)
        XCTAssertEqual(replayed.statistics.coverage, original.statistics.coverage)
    }

    func testLivePointsWinExactTimestampOverlapWithoutChangingSampleIdentity() {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let historical = [
            point(start, 0, 60),
            point(start, 1, 61),
            point(start, 2, 62),
        ]
        let live = [
            point(start, 1, 91),
            point(start, 3, 92),
            point(start, 3, 92),
        ]

        let historicalOnly = AtriaRecoveredHeartRateProjection.project(
            historical: historical,
            configuration: configuration
        )
        let merged = AtriaRecoveredHeartRateProjection.project(
            historical: historical,
            live: live,
            configuration: configuration
        )

        XCTAssertEqual(merged.samples.map(\.timestamp), (0...3).map {
            start.addingTimeInterval(Double($0))
        })
        XCTAssertEqual(merged.samples.map(\.bpm), [60, 91, 62, 92])
        XCTAssertEqual(merged.samples.map(\.source), [
            .historicalArchive, .live, .historicalArchive, .live,
        ])
        XCTAssertEqual(merged.statistics.liveOverrideCount, 1)
        XCTAssertEqual(merged.statistics.duplicateTimestampCount, 2)
        XCTAssertEqual(merged.statistics.coverage.historicalSampleCount, 2)
        XCTAssertEqual(merged.statistics.coverage.liveSampleCount, 2)
        XCTAssertEqual(merged.samples[1].stableKey,
                       historicalOnly.samples[1].stableKey,
                       "source replacement must remain idempotent")
    }

    func testSparseSamplesRemainSparseInsideOneWindow() throws {
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let first = point(start, 0, 80)
        let second = point(start, 5, 85)

        let result = AtriaRecoveredHeartRateProjection.project(
            historical: [second, first],
            configuration: configuration
        )

        let window = try XCTUnwrap(result.windows.only)
        XCTAssertEqual(window.samples.map(\.timestamp), [first.t, second.t])
        XCTAssertEqual(window.samples.map(\.bpm), [80, 85])
        XCTAssertEqual(window.coverage.timelineSpanSeconds, 5)
        XCTAssertEqual(window.coverage.coveredSeconds, 1)
        XCTAssertEqual(window.coverage.uncoveredSeconds, 4)
        XCTAssertEqual(window.coverage.coverageFraction, 0.2)
    }

    func testSameSourceConflictUsesDeterministicExistingSampleWithoutInventingBPM() {
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        let low = point(start, 0, 60)
        let high = point(start, 0, 65)

        let forward = AtriaRecoveredHeartRateProjection.project(
            historical: [low, high],
            configuration: configuration
        )
        let reversed = AtriaRecoveredHeartRateProjection.project(
            historical: [high, low],
            configuration: configuration
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.samples.map(\.bpm), [65])
        XCTAssertTrue([low.bpm, high.bpm].contains(forward.samples[0].bpm))
    }

    func testRecoveredSessionsContainNoDuplicatedLiveSamplesAndHaveStableIdentity() throws {
        let start = Date(timeIntervalSince1970: 1_800_500_000)
        let archive = [point(start, 0, 60), point(start, 1, 61), point(start, 2, 62)]
        let live = [point(start, 1, 91)]
        let projected = AtriaRecoveredHeartRateProjection.project(
            historical: archive,
            live: live,
            configuration: configuration
        )

        let first = AtriaRecoveredHeartRateProjection.recoveredSessions(
            from: projected,
            maximumGap: 10,
            timeZoneIdentifier: "UTC"
        )
        let replay = AtriaRecoveredHeartRateProjection.project(
            historical: archive.reversed(),
            live: live,
            configuration: configuration
        )
        let second = AtriaRecoveredHeartRateProjection.recoveredSessions(
            from: replay,
            maximumGap: 10,
            timeZoneIdentifier: "UTC"
        )

        let session = try XCTUnwrap(first.only)
        XCTAssertEqual(session.points.map(\.bpm), [60, 62])
        XCTAssertEqual(session.points.map(\.t), [0, 2])
        XCTAssertEqual(session.id, try XCTUnwrap(second.only).id)
        XCTAssertEqual(session.label, "Recovered strap HR")
        XCTAssertEqual(session.eventTimeZoneIdentifier, "UTC")
        XCTAssertEqual(session.hrAcceptedValue, 2)
        XCTAssertEqual(session.hrAcceptedGapsValue, 0)
        XCTAssertEqual(session.hrMaxAcceptedGapValue, 2)
    }

    func testVerifiedHistoricalRRIsAttachedExactlyOnceWithExplicitProvenance() throws {
        let start = Date(timeIntervalSince1970: 1_800_600_000)
        let projected = AtriaRecoveredHeartRateProjection.project(
            historical: [point(start, 0, 60), point(start, 20, 61)],
            configuration: .init(maximumGap: 10, expectedSampleInterval: 1)
        )
        let beat = AtriaRecoveredRRProjection.Beat(
            id: "beat-1",
            recordID: "record-1",
            timestamp: start.addingTimeInterval(-0.8),
            intervalMilliseconds: 800,
            counter: 1,
            beatIndex: 0,
            provenance: .verifiedWhoop4HistoricalV24
        )

        let sessions = AtriaRecoveredHeartRateProjection.recoveredSessions(
            from: projected,
            maximumGap: 10,
            recoveredRRBeats: [beat]
        )

        XCTAssertEqual(sessions.count, 2)
        let attached = try XCTUnwrap(sessions.first?.rrPoints?.only)
        XCTAssertEqual(attached.t, 0, accuracy: 0.000_001)
        XCTAssertEqual(attached.ms, 800)
        XCTAssertEqual(attached.source, .verifiedWhoop4HistoricalV24)
        XCTAssertNil(sessions.last?.rrPoints)
        XCTAssertTrue(try XCTUnwrap(sessions.first).hasQualifiedRRProvenance)
        XCTAssertFalse(try XCTUnwrap(sessions.first).hasQualifiedStandardRRProvenance)
    }

    private func point(_ start: Date,
                       _ offset: TimeInterval,
                       _ bpm: Int) -> HistoricalArchive.HeartRatePoint {
        HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(offset), bpm: bpm)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
