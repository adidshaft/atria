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
        let start = try XCTUnwrap(source.range(of: "private func healthspanDetailModel("))
        let end = try XCTUnwrap(source.range(of: "private var sleepDetailCard:",
                                             range: start.upperBound..<source.endIndex))
        let builder = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(builder.contains("AtriaFitnessAge.weeklyObservations("))
        XCTAssertFalse(builder.contains("AtriaFitnessAge.paceOfAging("))
        XCTAssertTrue(builder.contains("projection?.weeklyObservations"))
        XCTAssertTrue(builder.contains("projection?.paceOfAging"))
    }
}
