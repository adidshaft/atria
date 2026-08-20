import XCTest
@testable import Atria

/// P7 (2026-08-20 sleep-stage design, Track 2 §2.1): the per-stage typical
/// range baseline. Pure tests over `AtriaStageTypicalRange` — no store, no
/// defaults, no multi-save integration — plus the row strip's pure typical
/// sub-strip geometry. Fixture time bases are post-2026-08-06.
final class AtriaStageTypicalRangeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    /// Post-2026-08-06 fixture base; nights advance forward from here.
    private var baseDay: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 20))!
    }

    // MARK: - Night fixtures

    /// A contiguous, integrity-passing night: 30m awake, then light/deep/rem
    /// blocks. `duration` is the non-awake total so the night reconciles for
    /// presentation exactly like a real settled record.
    private func night(offset: Int,
                       deepMinutes: Double = 90,
                       lightMinutes: Double = 240,
                       remMinutes: Double = 90,
                       deepAsSWS: Bool = false,
                       estimateProvenance: Bool = false,
                       confirmed: Bool = true,
                       motionValidated: Bool? = true,
                       source: String = "sleep_window") -> SleepHistorySnapshot.Night {
        let day = calendar.date(byAdding: .day, value: offset, to: baseDay)!
        let start = calendar.date(byAdding: .hour, value: 22, to: day)!
        func mint(_ name: String) -> String {
            estimateProvenance
                ? SleepStageSegment.hrEstimateIDPrefix + "n\(offset)-\(name)"
                : "n\(offset)-\(name)"
        }
        var cursor = start
        func block(_ name: String, _ stage: SleepStageKind, _ minutes: Double) -> SleepStageSegment {
            let blockStart = cursor
            cursor = cursor.addingTimeInterval(minutes * 60)
            return SleepStageSegment(id: mint(name), start: blockStart, end: cursor, stage: stage)
        }
        let segments = [
            block("awake", .awake, 30),
            block("light", .light, lightMinutes),
            block("deep", deepAsSWS ? .sws : .deep, deepMinutes),
            block("rem", .rem, remMinutes)
        ]
        let duration = (lightMinutes + deepMinutes + remMinutes) * 60
        return SleepHistorySnapshot.Night(id: "typical-n\(offset)",
                                          day: day,
                                          start: start,
                                          end: cursor,
                                          duration: duration,
                                          restingHR: 54,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: 0.92,
                                          confidence: "user_confirmed",
                                          source: source,
                                          confirmed: confirmed,
                                          stageSegments: segments,
                                          motionValidated: motionValidated)
    }

    /// A confirmed daytime nap with a fully valid staged hour — excluded from
    /// the baseline by evidence class alone, not by broken data.
    private func confirmedNap(offset: Int) -> SleepHistorySnapshot.Night {
        let day = calendar.date(byAdding: .day, value: offset, to: baseDay)!
        let start = calendar.date(byAdding: .hour, value: 14, to: day)!
        let end = start.addingTimeInterval(60 * 60)
        return SleepHistorySnapshot.Night(id: "typical-nap\(offset)",
                                          day: day,
                                          start: start,
                                          end: end,
                                          duration: 60 * 60,
                                          restingHR: 58,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: 0.95,
                                          confidence: "user_confirmed",
                                          source: "auto_nap",
                                          confirmed: true,
                                          stageSegments: [
                                              SleepStageSegment(id: "nap\(offset)-light",
                                                                start: start,
                                                                end: end,
                                                                stage: .light)
                                          ],
                                          motionValidated: true)
    }

    /// Alternating deep 60m/90m so the deep band is a known non-degenerate
    /// mean ± 1 SD: mean 75m, SD 15m → 60m...90m.
    private func alternatingQualifiedNights(count: Int, startingAt offset: Int = 0)
        -> [SleepHistorySnapshot.Night] {
        (0..<count).map { index in
            night(offset: offset + index,
                  deepMinutes: index.isMultiple(of: 2) ? 60 : 90)
        }
    }

    // MARK: - Fixture sanity (the exclusions below must be evidence-class
    // exclusions, never accidents of broken fixtures)

    func testQualifiedFixtureActuallyQualifies() {
        let fixture = night(offset: 0)
        XCTAssertEqual(fixture.stageEvidence, .sensorResearch)
        XCTAssertTrue(fixture.hasValidatedMotionEvidence)
        XCTAssertFalse(fixture.isNapEvidence)
        XCTAssertFalse(fixture.displayStageSegments.isEmpty)
        XCTAssertTrue(AtriaStageTypicalRange.qualifies(fixture))
        XCTAssertEqual(fixture.stageDuration(.deep), 90 * 60, accuracy: 0.5)
    }

    func testEstimateFixtureIsALabeledEstimateDespiteContradictoryMotionFlag() {
        // The contradictory-record case: estimate-prefixed segment ids with a
        // legacy `motionValidated == true` flag. Evidence resolves to the
        // labeled estimate, and the baseline must treat it as one.
        let fixture = night(offset: 0, estimateProvenance: true, motionValidated: true)
        XCTAssertEqual(fixture.stageEvidence, .hrOnlyEstimate)
        XCTAssertTrue(fixture.hasValidatedMotionEvidence,
                      "the flag alone would have leaked this night into the baseline")
        XCTAssertFalse(AtriaStageTypicalRange.qualifies(fixture))
    }

    // MARK: - The 14-night gate (documented constant, referenced not re-typed)

    func testMinimumQualifiedNightsIsTheDocumentedSleepSurfaceFloor() {
        XCTAssertEqual(AtriaStageTypicalRange.minimumQualifiedNights, 14)
        XCTAssertEqual(AtriaStageTypicalRange.minimumQualifiedNights,
                       AtriaOvernightTypical.minimumQualifiedNights,
                       "one typical floor across the sleep surfaces")
    }

    func testHiddenBelowFourteenQualifiedNights() {
        let thirteen = alternatingQualifiedNights(count: 13)
        XCTAssertNil(AtriaStageTypicalRange.ranges(nights: thirteen))

        let fourteen = alternatingQualifiedNights(count: 14)
        XCTAssertNotNil(AtriaStageTypicalRange.ranges(nights: fourteen),
                        "the gate is exactly the documented minimum, not one more")
    }

    func testEmptyHistoryYieldsNil() {
        XCTAssertNil(AtriaStageTypicalRange.ranges(nights: []))
    }

    // MARK: - Estimate-night exclusion (HR-only estimates NEVER seed)

    func testEstimateNightsNeverCountTowardTheGate() {
        // 13 qualified + 5 estimate nights (with the contradictory motion
        // flag) is still below the gate: estimates never seed the baseline.
        var nights = alternatingQualifiedNights(count: 13)
        for index in 0..<5 {
            nights.append(night(offset: 13 + index,
                                deepMinutes: 600,
                                estimateProvenance: true,
                                motionValidated: true))
        }
        XCTAssertNil(AtriaStageTypicalRange.ranges(nights: nights))
    }

    func testEstimateNightsNeverShiftTheBandMath() throws {
        let qualified = alternatingQualifiedNights(count: 14)
        var withEstimates = qualified
        // Extreme, most-recent estimate outliers: were they seeding, the deep
        // band would explode far past 90 minutes.
        for index in 0..<5 {
            withEstimates.append(night(offset: 14 + index,
                                       deepMinutes: 600,
                                       estimateProvenance: true,
                                       motionValidated: true))
        }
        let baseline = try XCTUnwrap(AtriaStageTypicalRange.ranges(nights: qualified))
        let contaminated = try XCTUnwrap(AtriaStageTypicalRange.ranges(nights: withEstimates))
        XCTAssertEqual(contaminated, baseline,
                       "estimate nights must be invisible to the baseline math")
    }

    // MARK: - Nap and non-qualified exclusion

    func testConfirmedNapsNeverSeedTheBaseline() {
        var nights = alternatingQualifiedNights(count: 13)
        for index in 0..<3 {
            nights.append(confirmedNap(offset: 13 + index))
        }
        XCTAssertNil(AtriaStageTypicalRange.ranges(nights: nights),
                     "3 confirmed naps must not close a 13-night gap")
        XCTAssertFalse(AtriaStageTypicalRange.qualifies(confirmedNap(offset: 0)))
    }

    func testUnconfirmedAndMotionlessNightsNeverSeed() {
        XCTAssertFalse(AtriaStageTypicalRange.qualifies(night(offset: 0, confirmed: false)))
        XCTAssertFalse(AtriaStageTypicalRange.qualifies(night(offset: 0, motionValidated: false)),
                       "no validated motion, no baseline authority")

        var nights = alternatingQualifiedNights(count: 13)
        nights.append(night(offset: 13, confirmed: false))
        nights.append(night(offset: 14, motionValidated: false))
        XCTAssertNil(AtriaStageTypicalRange.ranges(nights: nights))
    }

    // MARK: - Mean ± 1 SD math

    func testBandIsMeanPlusMinusOnePopulationSD() throws {
        // 7×60m + 7×90m: mean 75m, population SD 15m → 60m...90m.
        let ranges = try XCTUnwrap(
            AtriaStageTypicalRange.ranges(nights: alternatingQualifiedNights(count: 14)))
        let deep = try XCTUnwrap(ranges[.deep])
        XCTAssertEqual(deep.lowerBound, 60 * 60, accuracy: 0.5)
        XCTAssertEqual(deep.upperBound, 90 * 60, accuracy: 0.5)

        // Stages identical on every night are degenerate (SD 0) and omitted —
        // a zero-width band is noise, not a typical range.
        XCTAssertNil(ranges[.light])
        XCTAssertNil(ranges[.rem])
        XCTAssertNil(ranges[.awake])
    }

    func testBandHelperMathDirectly() throws {
        let band = try XCTUnwrap(AtriaStageTypicalRange.band(values: [3600, 5400, 3600, 5400]))
        XCTAssertEqual(band.lowerBound, 3600, accuracy: 0.001)
        XCTAssertEqual(band.upperBound, 5400, accuracy: 0.001)

        XCTAssertNil(AtriaStageTypicalRange.band(values: []))
        XCTAssertNil(AtriaStageTypicalRange.band(values: [5400, 5400, 5400]),
                     "degenerate SD-0 input yields no band")
        // A duration band can never dip below zero.
        let floored = try XCTUnwrap(AtriaStageTypicalRange.band(values: [0, 0, 0, 7200]))
        XCTAssertEqual(floored.lowerBound, 0, accuracy: 0.001)
    }

    func testSWSSegmentsFoldIntoTheDeepBand() throws {
        let nights = (0..<14).map { index in
            night(offset: index,
                  deepMinutes: index.isMultiple(of: 2) ? 60 : 90,
                  deepAsSWS: true)
        }
        let ranges = try XCTUnwrap(AtriaStageTypicalRange.ranges(nights: nights))
        let deep = try XCTUnwrap(ranges[.deep], "stored SWS reaches the baseline as Deep")
        XCTAssertEqual(deep.lowerBound, 60 * 60, accuracy: 0.5)
        XCTAssertEqual(deep.upperBound, 90 * 60, accuracy: 0.5)
        XCTAssertTrue(Set(ranges.keys).isSubset(of: Set(SleepStageKind.displayOrder)),
                      "bands are keyed by display stages only — never a raw .sws key")
    }

    // MARK: - Recency window (most recent 30, explicit sort)

    func testOnlyTheMostRecentThirtyNightsSeed() throws {
        // 35 qualified nights; the oldest 5 carry an extreme deep duration
        // that must age out of "typical".
        var nights: [SleepHistorySnapshot.Night] = (0..<5).map {
            night(offset: $0, deepMinutes: 600)
        }
        nights.append(contentsOf: (5..<35).map { index in
            night(offset: index, deepMinutes: index.isMultiple(of: 2) ? 60 : 90)
        })

        let expectedDeepSeconds = (5..<35).map { index in
            TimeInterval((index.isMultiple(of: 2) ? 60 : 90) * 60)
        }
        let expected = try XCTUnwrap(AtriaStageTypicalRange.band(values: expectedDeepSeconds))

        let ascending = try XCTUnwrap(AtriaStageTypicalRange.ranges(nights: nights))
        XCTAssertEqual(try XCTUnwrap(ascending[.deep]), expected)

        // Snapshot producers differ on order (some are newest-first): the
        // recency window must come from the nights' own dates, not array order.
        let newestFirst = try XCTUnwrap(AtriaStageTypicalRange.ranges(nights: nights.reversed()))
        XCTAssertEqual(try XCTUnwrap(newestFirst[.deep]), expected)
    }

    // MARK: - Row strip typical sub-strip geometry (pure)

    func testTypicalBandFractionsShareTheWindowScale() throws {
        let band = try XCTUnwrap(
            AtriaSleepStageRowStripPresentation.typicalBand(range: 3600...5400,
                                                            nightSeconds: 4500,
                                                            windowSeconds: 8 * 3600))
        XCTAssertEqual(band.bandStartFraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(band.bandEndFraction, 0.1875, accuracy: 0.0001)
        XCTAssertEqual(band.nightFraction, 0.15625, accuracy: 0.0001)
    }

    func testTypicalBandScaleWidensInsteadOfClipping() throws {
        // A typical band beyond the window's length widens the shared scale —
        // the band's far edge lands exactly at 1, never off-lane.
        let band = try XCTUnwrap(
            AtriaSleepStageRowStripPresentation.typicalBand(range: 3600...36000,
                                                            nightSeconds: 1800,
                                                            windowSeconds: 8 * 3600))
        XCTAssertEqual(band.bandEndFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.bandStartFraction, 0.1, accuracy: 0.0001)
        XCTAssertEqual(band.nightFraction, 0.05, accuracy: 0.0001)
    }

    func testTypicalBandIsNilWithoutARealRange() {
        XCTAssertNil(AtriaSleepStageRowStripPresentation.typicalBand(range: nil,
                                                                     nightSeconds: 4500,
                                                                     windowSeconds: 8 * 3600))
        XCTAssertNil(AtriaSleepStageRowStripPresentation.typicalBand(range: 5400...5400,
                                                                     nightSeconds: 4500,
                                                                     windowSeconds: 8 * 3600),
                     "degenerate ranges draw nothing")
    }

    func testTypicalBandSurvivesAZeroWindowByScalingOffTheRange() throws {
        // Defensive: a malformed zero-length window must not divide by zero —
        // the scale falls back to the band's own upper bound.
        let band = try XCTUnwrap(
            AtriaSleepStageRowStripPresentation.typicalBand(range: 3600...5400,
                                                            nightSeconds: 0,
                                                            windowSeconds: 0))
        XCTAssertEqual(band.bandEndFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(band.nightFraction, 0, accuracy: 0.0001)
    }

    func testTypicalTextReadsRealDurations() {
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.typicalText(range: 3600...5400),
                       "Typically 1h 0m–1h 30m")
        XCTAssertEqual(AtriaSleepStageRowStripPresentation.typicalText(range: 0...(45 * 60)),
                       "Typically 0m–45m")
    }

    func testTypicalFootnoteCopyIsPinned() {
        XCTAssertEqual(
            AtriaSleepStageRowStripPresentation.typicalRangeFootnote,
            "Thin bars compare this sleep with your typical range (hatched) from recent motion-checked nights")
    }

    // MARK: - Source pin: optional input, zero mount-site churn

    func testStripTypicalInputDefaultsNilSoMountSitesAreUntouched() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let stripURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaSleepStageRows.swift")
        let strip = try String(contentsOf: stripURL, encoding: .utf8)

        XCTAssertTrue(strip.contains(
            "var typicalRanges: [SleepStageKind: ClosedRange<TimeInterval>]? = nil"),
            "the typical input is optional with a nil default — P5 mounts compile and render unchanged")
        XCTAssertTrue(strip.contains("AtriaSleepStageRowStripPresentation.typicalRangeFootnote"),
                      "the duration-scaled sub-strips are explained, never mystery pixels")
    }
}
