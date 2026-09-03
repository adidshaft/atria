import XCTest
@testable import Atria

/// 2026-09-02: the recovery check-in alert described itself as firing "when
/// a baseline-qualified recovery estimate is ready", engineering for the
/// trusted-baseline gate the app names elsewhere.
/// 2026-09-03: "trusted recovery score" was still a score the app does not
/// compute; the catalog now says the recovery is trusted enough to show.
final class AtriaAlertDescriptionCopyTests: XCTestCase {
    func testRecoveryCheckInDescriptionIsPlain() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaNotificationCategories.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("When today's recovery is trusted enough to show."))
        XCTAssertFalse(source.contains("baseline-qualified recovery estimate"))
        XCTAssertFalse(source.contains("When a trusted recovery score is ready."))
    }
}
