import XCTest
@testable import Atria

/// Face-Off RHR row (2026-07-07): the payload's optional `h` field must
/// round-trip through the link encoding, clamp against crafted values, and
/// stay compatible with links minted before the field existed.
final class AtriaFaceOffRHRTests: XCTestCase {
    private func makePayload(h: Int?) -> AtriaFaceOffPayload {
        AtriaFaceOffPayload(v: AtriaFaceOffPayload.currentVersion,
                            name: "Sam",
                            endEpochDay: 20_600,
                            days: [.init(o: 0, r: 70, s: 8.5, z: 7.2, h: h)])
    }

    private func metric(day: Date,
                        recovery: Int,
                        strain: Double) -> SavedDailyMetric {
        SavedDailyMetric(day: day,
                         recoveryPercent: recovery,
                         recoveryConfidence: "local",
                         hrv: nil,
                         restingHR: 55 + (recovery % 5),
                         respiratoryRate: nil,
                         sleepDuration: 7 * 3_600,
                         sleepSpan: nil,
                         sleepStart: nil,
                         sleepEnd: nil,
                         sleepSource: nil,
                         sleepStageSegments: [],
                         sleepConsistencyPercent: nil,
                         strain: strain)
    }

    func testRestingHRRoundTripsThroughLink() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: 55)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertEqual(decoded.days.first?.h, 55)
        XCTAssertEqual(decoded.averageRestingHR, 55)
    }

    func testLinkWithoutRestingHRStillDecodes() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: nil)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertNil(decoded.days.first?.h)
        XCTAssertNil(decoded.averageRestingHR)
        XCTAssertEqual(decoded.averageRecovery, 70)
    }

    func testCraftedRestingHRIsClamped() throws {
        let encoded = try XCTUnwrap(AtriaFaceOff.encode(makePayload(h: 9999)))
        let decoded = try XCTUnwrap(AtriaFaceOff.decode(encoded))
        XCTAssertEqual(decoded.days.first?.h, 120)
    }

    func testMakePayloadUsesNewestSevenOnOrBeforeTodayWithoutSortedInput() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 7, day: 9))!
        var history: [SavedDailyMetric] = []
        for offset in 0..<10 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            history.append(metric(day: day, recovery: 70 - offset, strain: Double(offset)))
        }
        let future = metric(day: calendar.date(byAdding: .day, value: 1, to: today)!,
                            recovery: 99,
                            strain: 21)
        let unordered = [history[8], history[3], future, history[0], history[6], history[1], history[4], history[2], history[9], history[5], history[7]]

        let payload = try XCTUnwrap(AtriaFaceOff.makePayload(name: "Sam", history: unordered, now: today))

        XCTAssertEqual(payload.days.count, 7)
        XCTAssertEqual(payload.days.map(\.o), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(payload.days.map(\.r), [70, 69, 68, 67, 66, 65, 64])
        XCTAssertFalse(payload.days.contains { $0.r == 99 }, "Future metrics must not be shared.")
    }
}
