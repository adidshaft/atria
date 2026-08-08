import XCTest
@testable import Atria

final class AtriaStressDetailViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testInputSortsMeasuredReadingsAndClampsOnlyToDisplayDomain() {
        let readings = [
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 4.2),
            AtriaStressDetailReading(date: now, score: -0.5)
        ]

        let input = AtriaStressDetailInput(state: scoredState(activation: 0.6),
                                           readings: readings,
                                           updatedAt: now)

        XCTAssertEqual(input.readings.map(\.date), [now, now.addingTimeInterval(60)])
        XCTAssertEqual(input.readings.map(\.score), [0, 3])
        XCTAssertEqual(try XCTUnwrap(input.score), 1.8, accuracy: 0.0001)
    }

    func testInputFramesRestoredHistoryToTheSameTwentyFourHoursItAnalyzes() {
        let staleElevated = (0..<20).map { index in
            AtriaStressDetailReading(
                date: now.addingTimeInterval(-47 * 3_600 + Double(index) * 30),
                score: 2.7
            )
        }
        let recentCalm = (0..<21).map { index in
            AtriaStressDetailReading(
                date: now.addingTimeInterval(-Double(20 - index) * 30),
                score: 0.4
            )
        }

        let input = AtriaStressDetailInput(state: scoredState(activation: 0.2),
                                           readings: staleElevated + recentCalm,
                                           updatedAt: now)

        XCTAssertEqual(input.readings, recentCalm)
        XCTAssertEqual(input.elevatedEvidence.readingCount, recentCalm.count)
        XCTAssertTrue(input.elevatedEvidence.windows.isEmpty,
                      "Old restored peaks outside the visible 24h must not enter its count or overlays")
    }

    func testNonScoredStateNeverDisplaysNumericScore() {
        let state = AtriaStressState(level: nil,
                                     label: "Warming up",
                                     detail: "Building a live read",
                                     kind: .warmingUp,
                                     confidence: 0,
                                     rawActivation: 0.9,
                                     hrvAvailable: false)

        let input = AtriaStressDetailInput(state: state, readings: [], updatedAt: nil)

        XCTAssertNil(input.score)
    }

    func testTimelineLeavesRealGapInsteadOfConnectingIt() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(60), score: 0.8),
            AtriaStressDetailReading(date: now.addingTimeInterval(6 * 60 + 1), score: 1.5)
        ]

        let points = AtriaStressTimelinePoint.segment(readings)

        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testTimelineUsesSingleSegmentAtGapBoundary() {
        let readings = [
            AtriaStressDetailReading(date: now, score: 0.4),
            AtriaStressDetailReading(date: now.addingTimeInterval(5 * 60), score: 0.8)
        ]

        XCTAssertEqual(AtriaStressTimelinePoint.segment(readings).map(\.segment), [0, 0])
    }

    func testElevatedEvidenceFindsOnlyMeasuredSustainedWindows() {
        let readings = stride(from: 0.0, through: 20 * 60.0, by: 30).map { offset in
            let minute = offset / 60
            let elevated = (5...9).contains(minute) || (14...18).contains(minute)
            return AtriaStressDetailReading(date: now.addingTimeInterval(offset),
                                             score: elevated ? 2.2 : 0.7)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertTrue(evidence.isSupported)
        XCTAssertEqual(evidence.windows.count, 2)
        XCTAssertEqual(evidence.countText, "2 elevated windows")
        XCTAssertEqual(evidence.windows.map(\.duration), [4 * 60, 4 * 60])
        XCTAssertTrue(evidence.windows.allSatisfy {
            $0.readingCount >= AtriaStressElevatedEvidence.minimumWindowReadings
        })
    }

    func testSparseElevatedReadingsSuppressWindowOverlayAndCount() {
        let readings = (0..<6).map { index in
            AtriaStressDetailReading(date: now.addingTimeInterval(Double(index) * 30),
                                     score: 2.5)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertFalse(evidence.isSupported)
        XCTAssertTrue(evidence.windows.isEmpty)
        XCTAssertNil(evidence.countText)
        XCTAssertNil(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                  updatedAt: readings.last?.date))
    }

    func testElevatedWindowAnalysisNeverBridgesARealTelemetryGap() {
        var readings = stride(from: 0.0, through: 2 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 2.4)
        }
        readings += stride(from: 4 * 60.0, through: 6 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 2.4)
        }
        readings += stride(from: 6.5 * 60.0, through: 17 * 60.0, by: 30).map {
            AtriaStressDetailReading(date: now.addingTimeInterval($0), score: 0.6)
        }

        let evidence = AtriaStressElevatedEvidence.analyze(readings)

        XCTAssertTrue(evidence.isSupported)
        XCTAssertTrue(evidence.windows.isEmpty)
        XCTAssertEqual(evidence.countText, "No elevated windows")
    }

    func testInterventionDetailUsesActiveMeasuredDurationAndScoringReason() throws {
        let readings = stride(from: 0.0, through: 15 * 60.0, by: 30).map { offset in
            AtriaStressDetailReading(date: now.addingTimeInterval(offset),
                                     score: offset >= 11 * 60 ? 2.3 : 0.6)
        }
        let evidence = AtriaStressElevatedEvidence.analyze(readings)
        let last = try XCTUnwrap(readings.last?.date)

        XCTAssertEqual(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                    updatedAt: last),
                       "4 min elevated · HR + HRV vs your baseline")
        XCTAssertNil(evidence.interventionDetail(state: scoredState(activation: 0.8),
                                                  updatedAt: last.addingTimeInterval(91)))
        XCTAssertNil(evidence.interventionDetail(state: AtriaStressState(
            level: .low,
            label: "Low",
            detail: "HR + HRV vs your baseline",
            kind: .scored,
            confidence: 0.85,
            rawActivation: 0.3,
            hrvAvailable: true
        ), updatedAt: last))
    }

    func testRelaxActionStatesItsThreeMinuteDuration() {
        XCTAssertEqual(AtriaStressDetailCopy.relaxButtonTitle, "Relax · 3 min")
    }

    func testStressHistoryCopyDoesNotRegressToSessionOnlyClaims() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let files = [
            "AtriaActivityMonitor.swift",
            "AtriaOverviewSections.swift",
            "AtriaStressDetailView.swift",
            "AtriaVitalsCollectionSections.swift",
        ]
        let corpus = try files.map {
            try String(contentsOf: sourceDirectory.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n").lowercased()

        for staleClaim in [
            "stress history is session-only",
            "doesn't yet save a daily stress history",
            "not a saved daily trend",
            "doesn't save a day-by-day stress history",
            "continuous stress timeline",
            "gaps mean the strap was not collecting",
        ] {
            XCTAssertFalse(corpus.contains(staleClaim), "stale stress copy: \(staleClaim)")
        }
        XCTAssertTrue(corpus.contains("first measured reading"))
        XCTAssertTrue(corpus.contains("gaps mean no stress score was recorded"))
    }

    private func scoredState(activation: Double) -> AtriaStressState {
        AtriaStressState(level: .medium,
                         label: "Medium",
                         detail: "HR + HRV vs your baseline",
                         kind: .scored,
                         confidence: 0.85,
                         rawActivation: activation,
                         hrvAvailable: true)
    }
}
