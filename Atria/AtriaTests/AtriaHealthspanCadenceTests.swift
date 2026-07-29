import XCTest
@testable import Atria

final class AtriaHealthspanCadenceTests: XCTestCase {
    func testDetailProjectionCollapsesDailyCopiesAndRoundTripsWithWeeklyCache() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                      month: 6,
                                                                      day: 1)))
        let deltas = (0..<5).flatMap { week -> [AtriaFitnessAge.DailyDelta] in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: week, to: monday) ?? monday
            return [
                .init(day: weekStart, delta: -week),
                .init(day: calendar.date(byAdding: .day, value: 2, to: weekStart) ?? weekStart,
                      delta: -(week + 1))
            ]
        }
        let projection = AtriaFitnessAge.detailProjection(deltas: deltas, calendar: calendar)

        XCTAssertEqual(projection.weeklyObservations.count, 5)
        XCTAssertEqual(projection.weeklyObservations.last?.delta, -5)
        XCTAssertTrue(projection.paceOfAging.isReady)
        XCTAssertEqual(projection.trendChangeText, "-4y")
        XCTAssertEqual(projection.cachedAt, projection.weeklyObservations.last?.day)

        let now = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: monday))
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let summary = BiologicalAgeSummary.building(chronologicalAge: profile.age,
                                                    blockers: ["history_learning"])
        let signature = SessionStore.BiologicalAgeCacheSignature(profileAge: profile.age,
                                                                  biologicalSex: profile.biologicalSex,
                                                                  maxHR: profile.maxHR,
                                                                  maxHRSource: profile.maxHRSource)
        let record = SessionStore.BiologicalAgeCacheRecord(
            schema: SessionStore.biologicalAgeCacheSchema,
            computedAt: now,
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                   sessionsLoaded: true,
                                                                   now: now,
                                                                   calendar: calendar),
            signature: signature,
            summary: summary,
            detailProjection: projection
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionStore.BiologicalAgeCacheRecord.self,
                                               from: encoded)

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.detailProjection, projection)
    }

    func testHealthspanPresentationDoesNotRebuildWeeklyHistory() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        let source = try String(contentsOf: appURL.appendingPathComponent("AtriaHealthScreen.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private static func model("))
        let end = try XCTUnwrap(source.range(of: "enum AtriaHealthMonitorGrid",
                                             range: start.upperBound..<source.endIndex))
        let builder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(builder.contains("AtriaFitnessAge.weeklyObservations("))
        XCTAssertFalse(builder.contains("AtriaFitnessAge.paceOfAging("))
        XCTAssertTrue(builder.contains("projection?.weeklyObservations"))
        XCTAssertTrue(builder.contains("projection?.paceOfAging"))
    }

    /// The 14–27 day early estimate must never render with confident
    /// authority: both fitness-age surfaces pin the visible qualifier.
    func testEarlyEstimateQualifierRendersOnBothFitnessAgeSurfaces() throws {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")

        let card = try String(contentsOf: appURL.appendingPathComponent("AtriaHealthScreen.swift"),
                              encoding: .utf8)
        XCTAssertTrue(card.contains("if let qualifier = summary.earlyEstimateQualifierText"))
        XCTAssertTrue(card.contains("guard !summary.isEarlyEstimate else { return .orange }"))

        let detail = try String(contentsOf: appURL.appendingPathComponent("AtriaHealthspanDetailView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(detail.contains("if let qualifier = model.summary.earlyEstimateQualifierText"))

        let engine = try String(contentsOf: appURL.appendingPathComponent("AtriaFitnessAge.swift"),
                                encoding: .utf8)
        XCTAssertTrue(engine.contains("static let earlyEstimateMinimumDays = 14"))
        XCTAssertTrue(engine.contains("static let confidentBaselineDays = 28"))
    }

    /// Cached summaries written before `earlyEstimateDayCount` existed must
    /// keep decoding — and decode as confident, never as early.
    func testSummaryCachedWithoutEarlyFieldDecodesAsConfident() throws {
        let confident = BiologicalAgeSummary(biologicalAge: 34,
                                             chronologicalAge: 38,
                                             ageDelta: -4,
                                             agingPaceText: "Fitness age",
                                             agingPaceDetail: "Prepared detail",
                                             factors: [],
                                             blockers: [],
                                             footnote: BiologicalAgeSummary.footnoteText)
        let encoded = try JSONEncoder().encode(confident)
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyJSON.removeValue(forKey: "earlyEstimateDayCount")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)

        let decoded = try JSONDecoder().decode(BiologicalAgeSummary.self, from: legacyData)
        XCTAssertNil(decoded.earlyEstimateDayCount)
        XCTAssertFalse(decoded.isEarlyEstimate)
        XCTAssertEqual(decoded, confident)
    }
}
