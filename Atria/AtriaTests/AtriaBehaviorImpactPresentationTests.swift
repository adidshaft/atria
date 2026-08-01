import XCTest
@testable import Atria

/// The significance gate is the product promise of the Behavior Impact card:
/// the footer PRINTS the rule, so the code has to obey it exactly — >=5 logged
/// nights and p < 0.10, no magnitude shortcut, no rounding slack.
final class AtriaBehaviorImpactPresentationTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let reference = Date(timeIntervalSince1970: 1_785_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.startOfDay(for: reference.addingTimeInterval(TimeInterval(-offset * 86_400)))
    }

    /// `recoveries[offset]` becomes the night `offset` days before the
    /// reference day. `loggedOffsets` get the tag.
    private func makeModel(recoveries: [Int],
                       loggedOffsets: Set<Int>,
                       tag: BehaviorJournalEntry.Tag = .alcohol,
                       hrv: [Int?]? = nil,
                       restingHR: [Int?]? = nil,
                       deepSleep: [Int?]? = nil) -> AtriaBehaviorImpactPresentation.Model {
        let nights = recoveries.enumerated().map { offset, recovery in
            AtriaBehaviorImpactPresentation.Night(day: day(offset),
                                                  recoveryPercent: recovery,
                                                  hrv: hrv?[offset],
                                                  restingHR: restingHR?[offset],
                                                  validatedDeepSleepMinutes: deepSleep?[offset])
        }
        let entries = loggedOffsets.sorted().map { offset in
            BehaviorJournalEntry(id: "e\(offset)",
                                 day: day(offset),
                                 createdAt: day(offset),
                                 tags: [tag])
        }
        return AtriaBehaviorImpactPresentation.model(nights: nights,
                                                     journalEntries: entries,
                                                     referenceDate: reference,
                                                     calendar: calendar)
    }

    // MARK: - The gate

    func testFourLoggedNightsNeverEarnABarNoMatterHowLargeTheEffect() throws {
        // A 40-point separation with a vanishing p — still withheld, because
        // four nights is not evidence.
        let recoveries = [20, 21, 19, 22] + Array(repeating: 70, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: [0, 1, 2, 3])

        XCTAssertTrue(model.significant.isEmpty)
        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertEqual(stat.loggedNights, 4)
        XCTAssertFalse(stat.passesSignificanceGate)
        XCTAssertEqual(stat.evidencePText, "learning")
        XCTAssertEqual(stat.classification, .noEffectYet)
    }

    func testFiveLoggedNightsWithASeparatedDistributionClearsTheGate() throws {
        let recoveries = [40, 42, 39, 41, 43] + Array(repeating: 72, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: [0, 1, 2, 3, 4])

        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertEqual(stat.loggedNights, AtriaBehaviorImpact.minimumLoggedDays)
        XCTAssertTrue(stat.passesSignificanceGate)
        XCTAssertLessThan(try XCTUnwrap(stat.pValue), AtriaBehaviorImpact.maximumPValue)
        XCTAssertEqual(model.significant.count, 1)
        XCTAssertNotNil(model.details[stat.id], "a gated row must carry a precomputed drill-in")
    }

    func testFewerThanFiveQuietNightsAlsoWithholdsTheRow() throws {
        // Ten logged nights but only four quiet ones: the comparison side is
        // just as much a part of "logged vs quiet" as the logged side.
        let recoveries = Array(repeating: 40, count: 10) + [80, 82, 79, 81]
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<10))

        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertEqual(stat.quietNights, 4)
        XCTAssertFalse(stat.passesSignificanceGate)
        XCTAssertEqual(stat.evidencePText, "learning")
    }

    func testOverlappingDistributionsStayLearningEvenWithPlentyOfNights() throws {
        let recoveries = [60, 58, 62, 61, 59, 63, 57, 60]
            + [61, 59, 60, 62, 58, 61, 60, 59, 62, 58, 60, 61]
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<8))

        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertGreaterThanOrEqual(stat.loggedNights, AtriaBehaviorImpact.minimumLoggedDays)
        XCTAssertGreaterThan(try XCTUnwrap(stat.pValue), AtriaBehaviorImpact.maximumPValue)
        XCTAssertFalse(stat.passesSignificanceGate)
        XCTAssertTrue(model.significant.isEmpty)
    }

    func testGateIsStrictlyBelowThreshold() {
        // Hand-built Stat: p exactly at the threshold must NOT pass, because
        // the printed rule is "p < 0.10", not "p <= 0.10".
        let atThreshold = AtriaBehaviorImpactPresentation.Stat(tag: .alcohol,
                                                              loggedNights: 12,
                                                              quietNights: 30,
                                                              loggedMeanRecovery: 55,
                                                              quietMeanRecovery: 62,
                                                              pValue: AtriaBehaviorImpact.maximumPValue)
        XCTAssertFalse(atThreshold.passesSignificanceGate)

        let justUnder = AtriaBehaviorImpactPresentation.Stat(tag: .alcohol,
                                                            loggedNights: 12,
                                                            quietNights: 30,
                                                            loggedMeanRecovery: 55,
                                                            quietMeanRecovery: 62,
                                                            pValue: AtriaBehaviorImpact.maximumPValue - 0.0001)
        XCTAssertTrue(justUnder.passesSignificanceGate)
    }

    func testUnscoredNightsCannotVote() {
        // Rows without a recovery score never become a Night, so a behavior
        // logged only on unscored days has nothing to compare.
        let metrics = (0..<10).map { offset in
            SavedDailyMetric(day: day(offset),
                             recoveryPercent: offset < 5 ? nil : 70,
                             recoveryConfidence: "ready",
                             hrv: nil,
                             restingHR: nil,
                             respiratoryRate: nil,
                             sleepDuration: nil,
                             sleepSpan: nil,
                             sleepStart: nil,
                             sleepEnd: nil,
                             sleepSource: nil,
                             sleepStageSegments: [],
                             sleepConsistencyPercent: nil,
                             strain: nil)
        }
        let nights = AtriaBehaviorImpactPresentation.nights(from: metrics, calendar: calendar)
        XCTAssertEqual(nights.count, 5)
        XCTAssertTrue(nights.allSatisfy { $0.recoveryPercent == 70 })
    }

    // MARK: - Watch / Supports classification

    func testSignificantNegativeBehaviorReadsAsWatch() throws {
        let recoveries = [40, 42, 39, 41, 43, 38] + Array(repeating: 72, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<6), tag: .alcohol)

        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertTrue(stat.passesSignificanceGate)
        XCTAssertLessThan(stat.impact, 0)
        XCTAssertEqual(stat.classification, .watch)
        XCTAssertEqual(stat.classification.label, "Watch")
    }

    func testSignificantPositiveBehaviorReadsAsSupports() throws {
        let recoveries = [82, 84, 81, 83, 85, 80] + Array(repeating: 55, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<6), tag: .meditation)

        let stat = try XCTUnwrap(model.stats.first)
        XCTAssertTrue(stat.passesSignificanceGate)
        XCTAssertGreaterThan(stat.impact, 0)
        XCTAssertEqual(stat.classification, .supports)
        XCTAssertEqual(stat.classification.label, "Supports")
    }

    func testSubThresholdBehaviorReadsAsNoEffectYetOnTheMap() throws {
        let recoveries = [60, 58, 62] + Array(repeating: 61, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: [0, 1, 2], tag: .lateMeal)

        let row = try XCTUnwrap(model.mapRows().first)
        XCTAssertEqual(row.classification, .noEffectYet)
        XCTAssertEqual(row.classification.label, "No effect yet")
    }

    func testMapAndChartNeverDisagreeAboutTheSameBehavior() throws {
        let recoveries = [40, 42, 39, 41, 43, 38] + Array(repeating: 72, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<6), tag: .alcohol)

        for row in model.mapRows() {
            let chartRow = model.significant.first { $0.id == row.id }
            if row.classification == .noEffectYet {
                XCTAssertNil(chartRow, "\(row.id) is on the chart but reads 'No effect yet' on the map")
            } else {
                XCTAssertNotNil(chartRow, "\(row.id) is classified but missing from the chart")
            }
        }
    }

    // MARK: - Copy and axis

    func testSignificanceFooterIsVerbatim() {
        XCTAssertEqual(AtriaBehaviorImpactPresentation.significanceFooter,
                       "Only behaviors with ≥5 logged nights and p < 0.10 are shown. "
                       + "Association, not proof — keep logging to sharpen it.")
    }

    func testImpactMapEmptyStateIsVerbatim() {
        XCTAssertEqual(AtriaBehaviorImpactPresentation.mapEmptyText,
                       "Impact map appears once behaviors and outcomes overlap in your history.")
    }

    func testTopMoverSentenceCarriesBothRealNightCounts() throws {
        let recoveries = [40, 42, 39, 41, 43, 38] + Array(repeating: 72, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<6), tag: .alcohol)
        let mover = try XCTUnwrap(model.topMover)

        XCTAssertTrue(mover.topMoverSentence.contains("On the 6 nights"))
        XCTAssertTrue(mover.topMoverSentence.contains("the other 20 nights"))
        XCTAssertTrue(mover.topMoverSentence.contains(mover.impactText))
    }

    func testAxisNeverClipsAnEffectLargerThanTheDesignEightPercent() throws {
        let recoveries = [20, 22, 19, 21, 23, 18] + Array(repeating: 78, count: 20)
        let model = makeModel(recoveries: recoveries, loggedOffsets: Set(0..<6))

        XCTAssertGreaterThan(model.axisMagnitude, 8)
        let stat = try XCTUnwrap(model.significant.first)
        XCTAssertLessThanOrEqual(model.barFraction(for: stat), 1)
    }

    func testEmptyModelHasNoAxisSurpriseAndNoRows() {
        let model = AtriaBehaviorImpactPresentation.Model.empty
        XCTAssertEqual(model.axisMagnitude, 8)
        XCTAssertTrue(model.mapRows().isEmpty)
        XCTAssertTrue(model.evidenceRows().isEmpty)
        XCTAssertNil(model.topMover)
    }

    func testPTextCollapsesVerySmallPValues() {
        XCTAssertEqual(AtriaBehaviorImpactPresentation.pText(0.004), "p < 0.01")
        XCTAssertEqual(AtriaBehaviorImpactPresentation.pText(0.02), "p = 0.02")
        XCTAssertEqual(AtriaBehaviorImpactPresentation.pText(nil), "learning")
    }

    // MARK: - Drill-in

    func testDistributionUsesFixedTwentyPointBins() {
        let nights = [5, 25, 45, 65, 85, 99].map {
            AtriaBehaviorImpactPresentation.Night(day: reference,
                                                  recoveryPercent: $0,
                                                  hrv: nil,
                                                  restingHR: nil,
                                                  validatedDeepSleepMinutes: nil)
        }
        let distribution = AtriaBehaviorImpactPresentation.distribution(for: nights)
        XCTAssertEqual(distribution.bins, [1, 1, 1, 1, 2])
        XCTAssertEqual(distribution.nights, 6)
    }

    func testShiftRowNeedsFiveRealReadingsOnBothSides() throws {
        // HRV present on every night -> a row. Resting HR present on only four
        // logged nights -> withheld rather than averaged over a thin sample.
        let hrv: [Int?] = Array(repeating: 48, count: 6) + Array(repeating: 60, count: 20)
        let resting: [Int?] = [58, 57, 59, 58] + [nil, nil] + Array(repeating: 52, count: 20)
        let recoveries = [40, 42, 39, 41, 43, 38] + Array(repeating: 72, count: 20)
        let model = makeModel(recoveries: recoveries,
                          loggedOffsets: Set(0..<6),
                          hrv: hrv,
                          restingHR: resting)

        let detail = try XCTUnwrap(model.details["alcohol"])
        XCTAssertEqual(detail.shifts.map(\.metric), [.hrv])
        XCTAssertEqual(detail.shifts.first?.deltaText, "-12 ms")
        XCTAssertEqual(detail.loggedNightList.count, 6)
    }

    func testDeepSleepIsOnlyClaimedForValidatedStageNights() {
        let segment = SleepStageSegment(id: "s1",
                                        start: reference,
                                        end: reference.addingTimeInterval(45 * 60),
                                        stage: .deep)
        func metric(source: String?) -> SavedDailyMetric {
            SavedDailyMetric(day: reference,
                             recoveryPercent: 60,
                             recoveryConfidence: "ready",
                             hrv: 50,
                             restingHR: 55,
                             respiratoryRate: nil,
                             sleepDuration: nil,
                             sleepSpan: nil,
                             sleepStart: nil,
                             sleepEnd: nil,
                             sleepSource: source,
                             sleepStageSegments: [segment],
                             sleepConsistencyPercent: nil,
                             strain: nil)
        }

        XCTAssertEqual(AtriaBehaviorImpactPresentation
            .validatedDeepSleepMinutes(for: metric(source: "validated_sleep_stages")), 45)
        // HR-only / estimated stages still exist in storage; they must never
        // become a displayed deep-sleep claim (2026-08-01 honesty pass).
        XCTAssertNil(AtriaBehaviorImpactPresentation
            .validatedDeepSleepMinutes(for: metric(source: "auto_confirmed_sleep_hr_only")))
        XCTAssertNil(AtriaBehaviorImpactPresentation.validatedDeepSleepMinutes(for: metric(source: nil)))
    }

    func testDrillInDetailsExistOnlyForGatedRows() throws {
        let recoveries = [40, 42, 39, 41, 43, 38] + Array(repeating: 72, count: 20)
        var entries = (0..<6).map {
            BehaviorJournalEntry(id: "a\($0)", day: day($0), createdAt: day($0), tags: [.alcohol])
        }
        entries += (0..<3).map {
            BehaviorJournalEntry(id: "m\($0)", day: day($0 + 10), createdAt: day($0 + 10), tags: [.meditation])
        }
        let nights = recoveries.enumerated().map { offset, recovery in
            AtriaBehaviorImpactPresentation.Night(day: day(offset),
                                                  recoveryPercent: recovery,
                                                  hrv: nil,
                                                  restingHR: nil,
                                                  validatedDeepSleepMinutes: nil)
        }
        let model = AtriaBehaviorImpactPresentation.model(nights: nights,
                                                          journalEntries: entries,
                                                          referenceDate: reference,
                                                          calendar: calendar)

        XCTAssertNotNil(model.details["alcohol"])
        XCTAssertNil(model.details["meditation"])
        XCTAssertEqual(model.stats.count, 2)
        XCTAssertEqual(model.stats.first?.id, "alcohol", "gated rows sort ahead of learning rows")
        XCTAssertEqual(model.loggedNights, 6 + 3)
        XCTAssertEqual(model.scoredNights, 26)
    }
}
