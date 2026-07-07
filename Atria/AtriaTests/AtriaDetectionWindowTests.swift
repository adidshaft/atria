import XCTest
@testable import Atria

/// DetectionEvent structured windows (2026-07-07, design backlog item 11):
/// the added optional window fields must round-trip and stay compatible with
/// ring-buffer entries logged before the fields existed.
final class AtriaDetectionWindowTests: XCTestCase {
    func testWindowRoundTripsThroughCodable() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let event = DetectionEvent(kind: "workoutDetected",
                                   detail: "fixture",
                                   windowStart: start,
                                   windowEnd: start.addingTimeInterval(1800))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DetectionEvent.self, from: data)
        XCTAssertEqual(decoded.windowStart, event.windowStart)
        XCTAssertEqual(decoded.windowEnd, event.windowEnd)
    }

    func testLegacyEventWithoutWindowDecodes() throws {
        // Shape of an entry persisted by a build that predates the fields.
        let legacy = #"{"id":"11111111-2222-3333-4444-555555555555","kind":"workoutDetected","date":742000000,"detail":"legacy"}"#
        let decoded = try JSONDecoder().decode(DetectionEvent.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.windowStart)
        XCTAssertNil(decoded.windowEnd)
        XCTAssertEqual(decoded.kind, "workoutDetected")
    }
}
