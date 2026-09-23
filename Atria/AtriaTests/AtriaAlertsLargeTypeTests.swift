import XCTest
@testable import Atria

/// 2026-09-02 XXXL screenshot of Alerts: the haptics grid hyphenated
/// "Recov-ery" because its one-column fallback keyed on accessibility sizes,
/// and the delivery-posture row squeezed its sentence beside "Enable
/// alerts". Both now switch at XX-Large, the largest standard sizes.
final class AtriaAlertsLargeTypeTests: XCTestCase {
    func testHapticsGridFallsToOneColumnFromXXLarge() {
        XCTAssertEqual(AtriaAlertSettingsGrid.columns(for: .large).count, 2)
        XCTAssertEqual(AtriaAlertSettingsGrid.columns(for: .xLarge).count, 2)
        XCTAssertEqual(AtriaAlertSettingsGrid.columns(for: .xxLarge).count, 1)
        XCTAssertEqual(AtriaAlertSettingsGrid.columns(for: .xxxLarge).count, 1)
        XCTAssertEqual(AtriaAlertSettingsGrid.columns(for: .accessibility1).count, 1)
    }

    func testDeliveryRowStacksAtLargeType() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHapticAlerts.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var noticeDynamicTypeSize"))
        XCTAssertTrue(source.contains("if noticeDynamicTypeSize >= .xxLarge {\n                VStack(alignment: .leading, spacing: 6) {"))
        XCTAssertEqual(source.components(separatedBy: "prominenceAction(state)").count - 1, 2, "one action builder feeds both layouts")
    }
}
