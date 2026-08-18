import XCTest
@testable import Atria

/// WP-5 / GAP-05+07 — the overnight HR-load projection stays truthful: exact
/// five-minute observed buckets, conservative HR-only activation, missing wear
/// stays a gap, and no surface calls the result "stress".
final class AtriaSleepStressProjectionTests: XCTestCase {
    private let sleepStart = Date(timeIntervalSince1970: 1_783_900_800)

    private func points(bpm: Int,
                        from: TimeInterval,
                        to: TimeInterval,
                        every: TimeInterval = 60) -> [HistoricalArchive.HeartRatePoint] {
        stride(from: from, through: to, by: every).map {
            HistoricalArchive.HeartRatePoint(t: sleepStart.addingTimeInterval($0), bpm: bpm)
        }
    }

    func testMissingBaselineAndShortWindowsFailClosed() {
        let noBaseline = AtriaSleepStressProjection.make(points: [],
                                                         sleepStart: sleepStart,
                                                         sleepEnd: sleepStart.addingTimeInterval(8 * 3_600),
                                                         restingHeartRate: nil)
        XCTAssertEqual(noBaseline.availability, .baselineNeeded)
        XCTAssertTrue(noBaseline.samples.isEmpty)

        let shortWindow = AtriaSleepStressProjection.make(points: [],
                                                          sleepStart: sleepStart,
                                                          sleepEnd: sleepStart.addingTimeInterval(30 * 60),
                                                          restingHeartRate: 52)
        XCTAssertEqual(shortWindow.availability, .insufficientWear)
    }

    func testBucketsAverageObservedSamplesAndMissingWearStaysAGap() {
        // 8h window. Wear: first 2h and last 2h; a 4h hole in the middle.
        let sleepEnd = sleepStart.addingTimeInterval(8 * 3_600)
        let wear = points(bpm: 56, from: 0, to: 2 * 3_600)
            + points(bpm: 60, from: 6 * 3_600, to: 8 * 3_600)
        let projection = AtriaSleepStressProjection.make(points: wear,
                                                         sleepStart: sleepStart,
                                                         sleepEnd: sleepEnd,
                                                         restingHeartRate: 52)

        XCTAssertEqual(projection.availability, .ready)
        // No bucket may exist inside the 4h hole — a gap is a gap.
        let holeStart = sleepStart.addingTimeInterval(2 * 3_600 + 5 * 60)
        let holeEnd = sleepStart.addingTimeInterval(6 * 3_600 - 5 * 60)
        XCTAssertFalse(projection.samples.contains { $0.date > holeStart && $0.date < holeEnd },
                       "missing wear must never produce an invented bucket")
        XCTAssertFalse(projection.heartRateSamples.contains { $0.date > holeStart && $0.date < holeEnd })
        // Buckets carry the observed mean.
        XCTAssertEqual(projection.heartRateSamples.first?.bpm ?? 0, 56, accuracy: 0.01)
        XCTAssertEqual(projection.heartRateSamples.last?.bpm ?? 0, 60, accuracy: 0.01)
    }

    /// Baseline migrated 2026-08-19 (field report item 9). The previous
    /// expectations pinned the miscalibration as intended behaviour: with
    /// rest 50 they asserted 63 bpm -> 3.0 ("resting + 3 + threshold saturates
    /// the 0-3 scale") and 58 bpm -> 1.5. But `PersonalBaseline.restingHR` is
    /// an EMA of the per-day SLEEPING near-minimum, not an awake resting rate,
    /// and ordinary REM sits 15-25 bpm above a sleeping minimum. Saturating at
    /// rest + 13 meant a physiologically unremarkable night pinned at the top
    /// of the scale for hours. The scale now spans something real.
    func testOvernightLoadIsCalibratedAgainstASleepingBaseline() {
        let sleepEnd = sleepStart.addingTimeInterval(8 * 3_600)
        let rest = 50
        // deadZone = max(6, 50 * 0.12) = 6; fullScale = max(24, 50 * 0.45) = 24.
        // score = clamp((mean - 50 - 6) / 24, 0, 1) * 3.

        let calm = AtriaSleepStressProjection.make(points: points(bpm: 52, from: 0, to: 8 * 3_600),
                                                   sleepStart: sleepStart,
                                                   sleepEnd: sleepEnd,
                                                   restingHeartRate: rest)
        XCTAssertEqual(calm.availability, .ready)
        XCTAssertTrue(calm.samples.allSatisfy { $0.score == 0 },
                      "at/near resting HR must not register load")

        // THE REGRESSION THIS TEST EXISTS FOR: an ordinary REM excursion, ~13 bpm
        // above the sleeping minimum, used to saturate the scale at 3.0 and be
        // reported to the user as a "high period" in alarm orange.
        let ordinaryREM = AtriaSleepStressProjection.make(points: points(bpm: 63, from: 0, to: 8 * 3_600),
                                                          sleepStart: sleepStart,
                                                          sleepEnd: sleepEnd,
                                                          restingHeartRate: rest)
        let remScore = ordinaryREM.samples.first?.score ?? 0
        XCTAssertEqual(remScore, 0.875, accuracy: 0.001)
        XCTAssertLessThan(remScore, 2.0,
                          "an ordinary REM excursion must not enter the elevated band")
        XCTAssertTrue(AtriaSleepStressProjection.highPeriods(samples: ordinaryREM.samples).isEmpty,
                      "a physiologically unremarkable night reports no elevated periods")

        // A genuinely unusual elevation still registers, and still saturates.
        let elevated = AtriaSleepStressProjection.make(points: points(bpm: 74, from: 0, to: 8 * 3_600),
                                                       sleepStart: sleepStart,
                                                       sleepEnd: sleepEnd,
                                                       restingHeartRate: rest)
        XCTAssertEqual(elevated.samples.first?.score ?? 0, 2.25, accuracy: 0.001)
        XCTAssertFalse(AtriaSleepStressProjection.highPeriods(samples: elevated.samples).isEmpty,
                       "resting + 24 is a real elevation and must be reported")

        let saturated = AtriaSleepStressProjection.make(points: points(bpm: 80, from: 0, to: 8 * 3_600),
                                                        sleepStart: sleepStart,
                                                        sleepEnd: sleepEnd,
                                                        restingHeartRate: rest)
        XCTAssertEqual(saturated.samples.first?.score ?? 0, 3.0, accuracy: 0.001,
                       "full scale is reached at resting + deadZone + fullScale")
    }

    /// The band scales with the wearer, because absolute nocturnal excursions
    /// grow with resting rate. A 13 bpm rise must not mean the same thing to a
    /// 45 bpm athlete and a 75 bpm baseline.
    func testOvernightLoadBandScalesWithTheWearersBaseline() {
        XCTAssertEqual(AtriaSleepStressProjection.load(forBucketMeanBPM: 45 + 13, restingHeartRate: 45),
                       AtriaSleepStressProjection.load(forBucketMeanBPM: 45 + 13, restingHeartRate: 45),
                       accuracy: 0.001)
        // Same absolute rise, higher baseline -> lower normalized load.
        let athlete = AtriaSleepStressProjection.load(forBucketMeanBPM: 45 + 20, restingHeartRate: 45)
        let higher = AtriaSleepStressProjection.load(forBucketMeanBPM: 75 + 20, restingHeartRate: 75)
        XCTAssertGreaterThan(athlete, higher)
        // Never negative, never above 3.
        XCTAssertEqual(AtriaSleepStressProjection.load(forBucketMeanBPM: 40, restingHeartRate: 55), 0, accuracy: 0.001)
        XCTAssertEqual(AtriaSleepStressProjection.load(forBucketMeanBPM: 220, restingHeartRate: 55), 3, accuracy: 0.001)
    }

    func testCoverageRuleRequiresTwelveBucketsAndRealSpan() {
        let sleepEnd = sleepStart.addingTimeInterval(8 * 3_600)
        // 11 buckets (55 min of wear) is not enough.
        let thin = AtriaSleepStressProjection.make(points: points(bpm: 55, from: 0, to: 54 * 60),
                                                   sleepStart: sleepStart,
                                                   sleepEnd: sleepEnd,
                                                   restingHeartRate: 52)
        XCTAssertEqual(thin.availability, .insufficientWear)

        // 13 buckets but all packed into ~1h of an 8h night — span too small.
        let packed = AtriaSleepStressProjection.make(points: points(bpm: 55, from: 0, to: 64 * 60),
                                                     sleepStart: sleepStart,
                                                     sleepEnd: sleepEnd,
                                                     restingHeartRate: 52)
        XCTAssertEqual(packed.availability, .insufficientWear,
                       "12+ buckets clustered into one corner of the night is not overnight coverage")
    }

    func testHighPeriodsMergeAdjacentBucketsButNeverBridgeGaps() {
        func sample(_ minutes: Double, score: Double) -> AtriaSleepStressProjection.Sample {
            .init(date: sleepStart.addingTimeInterval(minutes * 60), score: score)
        }
        // Two high runs separated by a 20-minute quiet/missing stretch.
        let samples = [
            sample(0, score: 2.4), sample(5, score: 2.9), sample(10, score: 2.1),
            sample(30, score: 2.6), sample(35, score: 2.2),
            sample(40, score: 1.0),   // below threshold — never part of a period
        ]
        let periods = AtriaSleepStressProjection.highPeriods(samples: samples)

        XCTAssertEqual(periods.count, 2, "a gap wider than one bucket must split periods")
        XCTAssertEqual(periods[0].start, sleepStart)
        XCTAssertEqual(periods[0].end, sleepStart.addingTimeInterval(10 * 60))
        XCTAssertEqual(periods[0].duration, 15 * 60,
                       "the final five-minute bucket counts toward the duration")
        XCTAssertEqual(periods[1].duration, 10 * 60)

        let single = AtriaSleepStressProjection.highPeriods(samples: [sample(0, score: 2.5)])
        XCTAssertEqual(single.first?.duration, 5 * 60,
                       "one bucket reads as one five-minute period, not zero time")
        XCTAssertTrue(AtriaSleepStressProjection.highPeriods(samples: [sample(0, score: 1.9)]).isEmpty)
    }

    func testHighMarksShareTimestampsAcrossBothChartModes() {
        let sleepEnd = sleepStart.addingTimeInterval(8 * 3_600)
        // Calm night with one elevated hour in the middle. The elevated hour is
        // 76 bpm rather than the old 62: this test is about the two chart modes
        // marking the SAME timestamps, so the middle hour just has to clear the
        // elevated band, and after the 2026-08-19 recalibration 62 bpm against a
        // resting-50 sleeping baseline is an ordinary REM excursion, not an
        // elevated period.
        let wear = points(bpm: 52, from: 0, to: 3 * 3_600)
            + points(bpm: 76, from: 3 * 3_600 + 60, to: 4 * 3_600)
            + points(bpm: 52, from: 4 * 3_600 + 60, to: 8 * 3_600)
        let projection = AtriaSleepStressProjection.make(points: wear,
                                                         sleepStart: sleepStart,
                                                         sleepEnd: sleepEnd,
                                                         restingHeartRate: 50)

        let highLoadDates = Set(projection.samples.filter { $0.score >= 2 }.map(\.date))
        XCTAssertFalse(highLoadDates.isEmpty)
        XCTAssertEqual(Set(projection.highHeartRateSamples.map(\.date)), highLoadDates,
                       "the HR trace must mark exactly the load mode's high timestamps")
    }

    /// GAP-05 acceptance: no production copy calls the HR-only overnight result
    /// "stress". Identifiers (AtriaSleepStress…) are fine; user-facing strings
    /// are not.
    func testNoUserFacingCopyCallsTheHROnlyResultStress() throws {
        let appDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let files = try FileManager.default.contentsOfDirectory(at: appDirectory,
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        let phrase = try NSRegularExpression(pattern: "\"[^\"\\n]*[sS]leep stress[^\"\\n]*\"")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let matches = phrase.matches(in: source,
                                         range: NSRange(source.startIndex..., in: source))
            XCTAssertTrue(matches.isEmpty,
                          "\(file.lastPathComponent) contains user-facing 'sleep stress' copy")
        }

        // The Sleep detail keeps rendering the trace in the night's recorded
        // event timezone (GAP-07).
        let monitor = try String(contentsOf: appDirectory.appendingPathComponent("AtriaActivityMonitor.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(monitor.contains("displayTimeZone: eventTimeZone"),
                      "Sleep detail must pass the night's recorded zone into the overnight card")
    }
}
