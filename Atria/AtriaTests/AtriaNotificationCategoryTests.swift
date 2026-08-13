import XCTest
@testable import Atria

/// The typed notification-category catalog (2026-08-13): every category the
/// scheduler can post must have exactly one settings toggle, honest copy, and
/// the documented default — shipped categories stay ON, new categories start
/// OFF so the user opts in.
final class AtriaNotificationCategoryTests: XCTestCase {
    private let settingsDefaultsKey = "atria.notificationSettings.v1"
    private var previousSettingsData: Data?

    override func setUp() {
        super.setUp()
        previousSettingsData = UserDefaults.standard.data(forKey: settingsDefaultsKey)
    }

    override func tearDown() {
        if let previousSettingsData {
            UserDefaults.standard.set(previousSettingsData, forKey: settingsDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: settingsDefaultsKey)
        }
        super.tearDown()
    }

    // MARK: Taxonomy shape

    func testEveryCategoryHasAUniqueKind() {
        let kinds = AtriaNotificationCategory.allCases.map(\.kind)
        XCTAssertEqual(kinds.count, Set(kinds).count, "duplicate kind strings")
        for kind in kinds {
            XCTAssertEqual(AtriaNotificationCategory.category(forKind: kind)?.kind, kind)
        }
    }

    func testDefaultsMatchTaxonomy() {
        let settings = AtriaNotificationSettings()
        for category in AtriaNotificationCategory.allCases {
            XCTAssertEqual(settings[keyPath: category.settingKeyPath],
                           category.defaultEnabled,
                           "\(category.rawValue) default drifted from the catalog")
        }
        // The two task-mandated defaults-on categories.
        XCTAssertTrue(AtriaNotificationCategory.morningSummary.defaultEnabled)
        XCTAssertTrue(AtriaNotificationCategory.strapBattery.defaultEnabled)
        // Every category added 2026-08-13 starts OFF.
        for category in [AtriaNotificationCategory.secondSleepPrimary,
                         .bedtimeWindDown,
                         .catchUpComplete,
                         .parkedInterval] {
            XCTAssertFalse(category.defaultEnabled,
                           "\(category.rawValue) must be opt-in")
            XCTAssertFalse(AtriaNotificationSettings().allows(kind: category.kind),
                           "\(category.kind) must not fire before the user opts in")
        }
    }

    func testBedtimeWindDownIsQuietByDefault() {
        XCTAssertTrue(AtriaNotificationCategory.bedtimeWindDown.deliversQuietly)
    }

    // MARK: allows(kind:) mapping

    func testTogglingEachCategoryFlipsExactlyItsKind() {
        for category in AtriaNotificationCategory.allCases {
            var settings = AtriaNotificationSettings()
            settings[keyPath: category.settingKeyPath] = true
            XCTAssertTrue(settings.allows(kind: category.kind))
            settings[keyPath: category.settingKeyPath] = false
            XCTAssertFalse(settings.allows(kind: category.kind),
                           "disabling \(category.rawValue) must gate kind \(category.kind)")
            for other in AtriaNotificationCategory.allCases where other != category {
                XCTAssertEqual(settings.allows(kind: other.kind),
                               settings[keyPath: other.settingKeyPath],
                               "disabling \(category.rawValue) leaked into \(other.rawValue)")
            }
        }
    }

    func testMasterSwitchGatesEveryCategoryButNeverDiagnostic() {
        var settings = AtriaNotificationSettings()
        settings.allowNotifications = false
        for category in AtriaNotificationCategory.allCases {
            XCTAssertFalse(settings.allows(kind: category.kind))
        }
        XCTAssertTrue(settings.allows(kind: "diagnostic"),
                      "the developer delivery probe is never user-gated")
        XCTAssertEqual(settings.enabledCount, 0)
    }

    // MARK: Persistence

    func testSaveLoadRoundTripPersistsEveryToggle() {
        var settings = AtriaNotificationSettings()
        settings.secondSleepPrimary = true
        settings.bedtimeWindDown = true
        settings.sleepReview = false
        settings.syncNudge = false
        settings.save()
        let loaded = AtriaNotificationSettings.load()
        XCTAssertEqual(loaded, settings)
        XCTAssertTrue(loaded.allows(kind: "second_sleep_primary"))
        XCTAssertTrue(loaded.allows(kind: "bedtime_reminder"))
        XCTAssertFalse(loaded.allows(kind: "sleep_review"))
        XCTAssertFalse(loaded.allows(kind: "sync_nudge"))
    }

    func testDecodingALegacyPayloadKeepsShippedDefaultsAndNewCategoriesOff() throws {
        // A payload written before 2026-08-13 has none of the new fields.
        let legacy = Data(#"{"allowNotifications":true,"recoveryReady":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AtriaNotificationSettings.self, from: legacy)
        XCTAssertFalse(decoded.recoveryReady)
        XCTAssertTrue(decoded.sleepLogged, "previously implicit kinds keep their effective default")
        XCTAssertTrue(decoded.eveningCheckIn)
        XCTAssertTrue(decoded.syncNudge)
        XCTAssertFalse(decoded.secondSleepPrimary)
        XCTAssertFalse(decoded.bedtimeWindDown)
        XCTAssertFalse(decoded.catchUpComplete)
        XCTAssertFalse(decoded.parkedInterval)
    }

    // MARK: Copy honesty

    /// The app never over-claims: no medical/fever/illness language, no
    /// "recovery score" it does not compute, in ANY string the notification
    /// system can show the user.
    func testNotificationCopyNeverOverclaims() {
        let forbidden = ["fever", "illness", "diagnos", "disease", "medical",
                         "infection", "virus", "sick", "recovery score",
                         "symptom", "cure", "treat"]
        var copy: [String] = []
        for category in AtriaNotificationCategory.allCases {
            copy.append(category.displayName)
            copy.append(category.honestDescription)
        }
        let secondSleep = AtriaEventNotificationContent.secondSleepPrompt(dayText: "Aug 13")
        let catchUp = AtriaEventNotificationContent.catchUpComplete()
        let parked = AtriaEventNotificationContent.parkedInterval()
        let bedtimeNoDebt = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: nil)
        let bedtimeDebt = AtriaBedtimeWindDownPolicy.content(sleepDebtHours: 3.0)
        for content in [secondSleep, catchUp, parked, bedtimeNoDebt, bedtimeDebt] {
            copy.append(content.title)
            copy.append(content.body)
        }
        for text in copy {
            let lowered = text.lowercased()
            for term in forbidden {
                XCTAssertFalse(lowered.contains(term),
                               "forbidden term \"\(term)\" in copy: \(text)")
            }
        }
    }

    /// Unproven values never appear as numbers: the sync-truth and bedtime
    /// notifications describe states, not measurements, so their copy carries
    /// no digits at all.
    func testStateNotificationsCarryNoNumbers() {
        let stateCopy = [
            AtriaEventNotificationContent.catchUpComplete(),
            AtriaEventNotificationContent.parkedInterval(),
            AtriaBedtimeWindDownPolicy.content(sleepDebtHours: nil),
            AtriaBedtimeWindDownPolicy.content(sleepDebtHours: 5.9),
        ]
        for content in stateCopy {
            XCTAssertNil(content.body.rangeOfCharacter(from: .decimalDigits),
                         "unproven numeric claim in: \(content.body)")
            XCTAssertNil(content.title.rangeOfCharacter(from: .decimalDigits))
        }
    }
}
