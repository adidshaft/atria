import XCTest
@testable import Atria

final class AtriaGlanceSettingsTests: XCTestCase {
    typealias G = AtriaGlanceSettings

    private func freshDefaults() -> UserDefaults {
        let name = "atria.glance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsKeepTodaysBehaviour() {
        let d = freshDefaults()
        XCTAssertEqual(G.liveActivityMode(in: d), .always, "all-day live HR stays the default")
        XCTAssertEqual(G.liveItems(in: d), Set(G.LiveItem.allCases))
    }

    func testChoicesRoundTripIncludingHeartRateOnly() {
        let d = freshDefaults()
        G.setLiveActivityMode(.workouts, in: d)
        XCTAssertEqual(G.liveActivityMode(in: d), .workouts)
        G.setLiveItems([.steps], in: d)
        XCTAssertEqual(G.liveItems(in: d), [.steps])
        G.setLiveItems([], in: d)
        XCTAssertEqual(G.liveItems(in: d), [], "all items off is a valid choice (heart rate only)")
    }

    func testModeGatesIdlePresenceAndWorkouts() {
        XCTAssertTrue(G.LiveActivityMode.always.allowsIdlePresence)
        XCTAssertFalse(G.LiveActivityMode.workouts.allowsIdlePresence)
        XCTAssertTrue(G.LiveActivityMode.workouts.allowsWorkoutActivity)
        XCTAssertFalse(G.LiveActivityMode.off.allowsWorkoutActivity)
        for mode in [G.LiveActivityMode.workouts, .off] {
            XCTAssertFalse(AtriaLiveActivityCoordinator.idleLivePresenceShouldStayActive(
                workoutActive: false, linkUsable: true, heldHeartRate: 70,
                presenceAlreadyStarted: true, mode: mode))
        }
        XCTAssertTrue(AtriaLiveActivityCoordinator.idleLivePresenceShouldStayActive(
            workoutActive: false, linkUsable: true, heldHeartRate: 70,
            presenceAlreadyStarted: false, mode: .always))
    }

    /// App and widget extension compile separate folders; the store must be
    /// one definition.
    func testAppAndWidgetCopiesAreIdentical() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Atria/AtriaGlanceSettings.swift"), encoding: .utf8)
        let widget = try String(contentsOf: root.appendingPathComponent("AtriaWidget/AtriaGlanceSettings.swift"), encoding: .utf8)
        XCTAssertEqual(app, widget)
    }

    func testLockScreenLiveActivityHonoursChosenItems() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let widget = try String(contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        XCTAssertTrue(widget.contains("lockScreenHeader(showsBattery: items.contains(.battery))"))
        XCTAssertTrue(widget.contains("if items.contains(.zone) {"))
        XCTAssertTrue(widget.contains("items.contains(.steps)"))
        XCTAssertTrue(widget.contains(".padding(.horizontal, 16)"), "Lock Screen content needs real insets")
    }
}
