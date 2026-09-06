import XCTest
@testable import Atria

/// 2026-09-02: the breathwork session reported its change as "RMSSD +5 ms",
/// the engine's name for the number the wearer knows as HRV.
final class AtriaBreathworkResultCopyTests: XCTestCase {
    func testDeltaIsNamedHRV() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaBreathworkSession.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("rmssdDelta.map { \"HRV \\($0 >= 0 ? \"+\" : \"\")\\($0) ms\" }"))
        XCTAssertFalse(source.contains("\"RMSSD \\("))
    }
}
