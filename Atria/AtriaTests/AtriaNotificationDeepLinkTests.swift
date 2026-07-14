import XCTest
import UserNotifications
@testable import Atria

@MainActor
final class AtriaNotificationDeepLinkTests: XCTestCase {
    func testColdLaunchInboxRetainsJournalRouteUntilHomeConsumesIt() throws {
        let center = NotificationCenter()
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: center)
        let url = try XCTUnwrap(URL(string: "atria://journal"))

        XCTAssertTrue(inbox.enqueue(url, responseKey: "morning|default"))
        XCTAssertEqual(inbox.consume(), url)
        XCTAssertNil(inbox.consume())
    }

    func testDuplicateResponseIsIdempotentBeforeAndAfterConsumption() throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let url = try XCTUnwrap(URL(string: "atria://journal"))

        XCTAssertTrue(inbox.enqueue(url, responseKey: "evening|default"))
        XCTAssertFalse(inbox.enqueue(url, responseKey: "evening|default"))
        XCTAssertEqual(inbox.consume(), url)
        XCTAssertFalse(inbox.enqueue(url, responseKey: "evening|default"))
        XCTAssertNil(inbox.consume())
    }

    func testInboxRejectsRoutesOutsideAtria() throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let url = try XCTUnwrap(URL(string: "https://example.com/journal"))

        XCTAssertFalse(inbox.enqueue(url, responseKey: "external"))
        XCTAssertNil(inbox.consume())
    }

    func testJournalActionOverridesMorningSummaryDefaultDestination() {
        XCTAssertEqual(
            NotificationDeliveryLogger.resolvedDeepLink(
                deepLink: "atria://overview",
                actionIdentifier: "atria.action.logJournal"
            )?.absoluteString,
            "atria://journal"
        )
    }

    func testDefaultTapUsesScheduledJournalDestinationAndRejectsExternalURL() {
        XCTAssertEqual(
            NotificationDeliveryLogger.resolvedDeepLink(
                deepLink: "atria://journal",
                actionIdentifier: UNNotificationDefaultActionIdentifier
            )?.absoluteString,
            "atria://journal"
        )
        XCTAssertNil(NotificationDeliveryLogger.resolvedDeepLink(
            deepLink: "https://example.com",
            actionIdentifier: UNNotificationDefaultActionIdentifier
        ))
    }

    func testMorningAndEveningJournalIdentifiersRouteWithoutUserInfo() {
        for identifier in [
            "atria.morningJournal.2026-07-15",
            "atria.eveningJournal.2026-07-14"
        ] {
            XCTAssertEqual(
                NotificationDeliveryLogger.resolvedDeepLink(
                    deepLink: nil,
                    actionIdentifier: UNNotificationDefaultActionIdentifier,
                    requestIdentifier: identifier
                )?.absoluteString,
                "atria://journal"
            )
        }
    }

    func testAppDelegateRegistersNotificationRoutingAtLaunch() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("didFinishLaunchingWithOptions"))
        XCTAssertTrue(source.contains("LocalNotificationScheduler.configureForApplicationLaunch()"))
    }
}
