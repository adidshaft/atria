import XCTest
@testable import Atria

/// 2026-09-02: the recovery check-in alert described itself as firing "when
/// a baseline-qualified recovery estimate is ready", engineering for the
/// trusted-baseline gate the app names elsewhere. It now says trusted.
final class AtriaAlertDescriptionCopyTests: XCTestCase {
    func testRecoveryCheckInDescriptionIsPlain() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaNotificationCategories.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("When a trusted recovery score is ready."))
        XCTAssertFalse(source.contains("baseline-qualified recovery estimate"))
    }
}
