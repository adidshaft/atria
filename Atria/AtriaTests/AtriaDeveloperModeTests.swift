import XCTest
@testable import Atria

final class AtriaDeveloperModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AtriaDeveloperModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLaunchArgumentPersistsLeaseHonoredByRelaunchWithoutArgument() {
        let launchedAt = Date(timeIntervalSince1970: 1_784_312_000)

        XCTAssertTrue(AtriaDeveloperMode.isEnabled(
            arguments: ["Atria", AtriaDeveloperMode.launchArgument],
            defaults: defaults,
            now: launchedAt
        ))
        XCTAssertTrue(defaults.bool(forKey: AtriaDeveloperMode.defaultsKey))
        XCTAssertEqual(defaults.object(forKey: AtriaDeveloperMode.expiryDefaultsKey) as? Date,
                       launchedAt.addingTimeInterval(AtriaDeveloperMode.leaseDuration))

        XCTAssertTrue(AtriaDeveloperMode.isEnabled(
            arguments: ["Atria"],
            defaults: defaults,
            now: launchedAt.addingTimeInterval(60 * 60)
        ))
    }

    func testExpiredLeaseIsRejectedAndCleared() {
        let launchedAt = Date(timeIntervalSince1970: 1_784_312_000)
        _ = AtriaDeveloperMode.isEnabled(
            arguments: ["Atria", AtriaDeveloperMode.launchArgument],
            defaults: defaults,
            now: launchedAt
        )

        XCTAssertFalse(AtriaDeveloperMode.isEnabled(
            arguments: ["Atria"],
            defaults: defaults,
            now: launchedAt.addingTimeInterval(AtriaDeveloperMode.leaseDuration)
        ))
        XCTAssertNil(defaults.object(forKey: AtriaDeveloperMode.defaultsKey))
        XCTAssertNil(defaults.object(forKey: AtriaDeveloperMode.expiryDefaultsKey))
    }

    func testExplicitExitClearsPersistedLease() {
        let launchedAt = Date(timeIntervalSince1970: 1_784_312_000)
        _ = AtriaDeveloperMode.isEnabled(
            arguments: ["Atria", AtriaDeveloperMode.launchArgument],
            defaults: defaults,
            now: launchedAt
        )

        AtriaDeveloperMode.disable(defaults: defaults)

        XCTAssertFalse(AtriaDeveloperMode.isEnabled(
            arguments: ["Atria"],
            defaults: defaults,
            now: launchedAt.addingTimeInterval(60)
        ))
        XCTAssertNil(defaults.object(forKey: AtriaDeveloperMode.defaultsKey))
        XCTAssertNil(defaults.object(forKey: AtriaDeveloperMode.expiryDefaultsKey))
    }
}
