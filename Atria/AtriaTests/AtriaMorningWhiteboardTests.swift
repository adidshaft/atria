import XCTest
@testable import Atria

/// Assessment P0.4 — the morning whiteboard leads with measured numbers and
/// personal bands; untrusted baselines calibrate instead of inventing bands,
/// and the sleep row reads only the frozen need.
final class AtriaMorningWhiteboardTests: XCTestCase {
    private func trustedBaseline() -> AtriaBaselineTargetSnapshot {
        var baseline = PersonalBaseline()
        // Anchor at the present: the snapshot judges trust against the
        // 14-day freshness window, so a fixed historical epoch reads stale.
        let start = Date().addingTimeInterval(-15 * 86_400)
        for day in 0..<16 {
            baseline.learn(fromResting: 50 + day % 2,
                           hrv: 60 + day % 3,
                           at: start.addingTimeInterval(Double(day) * 86_400),
                           overnight: true)
        }
        return AtriaBaselineTargetSnapshot(baseline)
    }

    func testTrustedBaselinesProduceBandsAndTones() throws {
        let model = AtriaTodayMorningWhiteboardModel.make(hrvMS: 61,
                                                          restingHR: 50,
                                                          baseline: trustedBaseline(),
                                                          sleepDurationText: "7h 10m",
                                                          nightConfirmed: true,
                                                          needHours: 7.7,
                                                          yesterdayTRIMP: 188.4,
                                                          yesterdayStrain: 12.4,
                                                          yesterdayStrainIsPartial: true)
        XCTAssertEqual(model.rows.map(\.id), ["hrv", "rhr", "sleep", "yesterday"])

        let hrv = try XCTUnwrap(model.rows.first { $0.id == "hrv" })
        XCTAssertTrue(hrv.sentence.hasPrefix("typical "), "a trusted baseline draws its band")
        XCTAssertEqual(hrv.tone, .supportive)

        let rhr = try XCTUnwrap(model.rows.first { $0.id == "rhr" })
        XCTAssertTrue(rhr.sentence.contains("bpm"))
        XCTAssertEqual(rhr.tone, .supportive)

        let sleep = try XCTUnwrap(model.rows.first { $0.id == "sleep" })
        XCTAssertEqual(sleep.sentence, "of \(AtriaMetricFormat.sleepHours(7.7)) need",
                       "the sleep row quotes the frozen need, never a recomputation")

        let yesterday = try XCTUnwrap(model.rows.first { $0.id == "yesterday" })
        XCTAssertTrue(yesterday.sentence.contains("partial"),
                      "partial strain coverage is disclosed on the whiteboard")
        XCTAssertEqual(yesterday.valuePhrase, "TRIMP 188 (12.4)",
                       "yesterday leads with persisted TRIMP truth; 0–21 stays a parenthetical skin (§13.2)")
    }

    func testUntrustedBaselineCalibratesInsteadOfInventingABand() throws {
        let model = AtriaTodayMorningWhiteboardModel.make(hrvMS: 61,
                                                          restingHR: 50,
                                                          baseline: AtriaBaselineTargetSnapshot(PersonalBaseline()),
                                                          sleepDurationText: nil,
                                                          nightConfirmed: nil,
                                                          needHours: nil,
                                                          yesterdayTRIMP: nil,
                                                          yesterdayStrain: nil,
                                                          yesterdayStrainIsPartial: false)
        let hrv = try XCTUnwrap(model.rows.first { $0.id == "hrv" })
        XCTAssertTrue(hrv.sentence.contains("of 14 nights"))
        XCTAssertEqual(hrv.tone, .neutral)

        let sleep = try XCTUnwrap(model.rows.first { $0.id == "sleep" })
        XCTAssertEqual(sleep.sentence, "awaiting tonight's sleep")

        let yesterday = try XCTUnwrap(model.rows.first { $0.id == "yesterday" })
        XCTAssertEqual(yesterday.sentence, "no strain recorded yesterday")
        XCTAssertEqual(yesterday.valuePhrase, "Strain —")
    }

    func testLegacyConfirmedNightDisclosesMissingNeedInsteadOfInventingOne() throws {
        let model = AtriaTodayMorningWhiteboardModel.make(hrvMS: nil,
                                                          restingHR: nil,
                                                          baseline: AtriaBaselineTargetSnapshot(PersonalBaseline()),
                                                          sleepDurationText: "6h 40m",
                                                          nightConfirmed: true,
                                                          needHours: nil,
                                                          yesterdayTRIMP: nil,
                                                          yesterdayStrain: 8.0,
                                                          yesterdayStrainIsPartial: false)
        let sleep = try XCTUnwrap(model.rows.first { $0.id == "sleep" })
        XCTAssertEqual(sleep.sentence, "need unavailable for this legacy night")
        let yesterday = try XCTUnwrap(model.rows.first { $0.id == "yesterday" })
        XCTAssertEqual(yesterday.valuePhrase, "Strain 8.0",
                       "legacy rollup rows keep the display score — TRIMP is never rebuilt by inverting the curve")
    }

    func testYesterdayTRIMPWithoutStrainStandsAloneAndReadsAsRecorded() throws {
        let model = AtriaTodayMorningWhiteboardModel.make(hrvMS: nil,
                                                          restingHR: nil,
                                                          baseline: AtriaBaselineTargetSnapshot(PersonalBaseline()),
                                                          sleepDurationText: nil,
                                                          nightConfirmed: nil,
                                                          needHours: nil,
                                                          yesterdayTRIMP: 92.6,
                                                          yesterdayStrain: nil,
                                                          yesterdayStrainIsPartial: false)
        let yesterday = try XCTUnwrap(model.rows.first { $0.id == "yesterday" })
        XCTAssertEqual(yesterday.valuePhrase, "TRIMP 93")
        XCTAssertEqual(yesterday.sentence, "yesterday",
                       "a recorded TRIMP must not read as 'no strain recorded'")
    }
}
