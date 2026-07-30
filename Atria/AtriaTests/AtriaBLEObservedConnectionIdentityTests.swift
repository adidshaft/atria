import XCTest
@testable import Atria

@MainActor
final class AtriaBLEObservedConnectionIdentityTests: XCTestCase {
    func testObservedConnectedIdentityPersistsWhenDidConnectWasSkipped() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = UUID()

        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            identifier.uuidString
        )
    }

    func testObservedConnectedIdentityIsIdempotentForSamePeripheral() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identifier = UUID()

        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                defaults: defaults
            )
        )
        XCTAssertFalse(
            AtriaBLEManager.persistObservedConnectedIdentity(
                identifier,
                defaults: defaults
            )
        )
    }

    func testObservedConnectedIdentityReplacesStaleBond() throws {
        let suiteName = "AtriaBLEObservedConnectionIdentityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldIdentifier = UUID()
        let newIdentifier = UUID()
        defaults.set(
            oldIdentifier.uuidString,
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        )

        XCTAssertTrue(
            AtriaBLEManager.persistObservedConnectedIdentity(
                newIdentifier,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            defaults.string(
                forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
            ),
            newIdentifier.uuidString
        )
    }
}
