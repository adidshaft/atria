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

    func testOlderResponseReplayStaysIdempotentAfterAnotherResponseWasConsumed() throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let journal = try XCTUnwrap(URL(string: "atria://journal"))
        let overview = try XCTUnwrap(URL(string: "atria://overview"))

        XCTAssertTrue(inbox.enqueue(journal, responseKey: "morning|default"))
        XCTAssertEqual(inbox.consume(), journal)
        XCTAssertTrue(inbox.enqueue(overview, responseKey: "summary|default"))
        XCTAssertEqual(inbox.consume(), overview)

        XCTAssertFalse(inbox.enqueue(journal, responseKey: "morning|default"))
        XCTAssertNil(inbox.consume())
    }

    func testInboxRejectsRoutesOutsideAtria() throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let url = try XCTUnwrap(URL(string: "https://example.com/journal"))

        XCTAssertFalse(inbox.enqueue(url, responseKey: "external"))
        XCTAssertNil(inbox.consume())
    }

    func testColdLaunchEnqueueDoesNotRequireMainActor() async throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let url = try XCTUnwrap(URL(string: "atria://journal"))

        let accepted = await Task.detached {
            inbox.enqueue(url, responseKey: "cold-launch|default")
        }.value

        XCTAssertTrue(accepted)
        XCTAssertEqual(inbox.consume(), url)
    }

    func testRouteWaitsForActiveSceneInsteadOfBeingLostDuringTransition() {
        XCTAssertFalse(AtriaNotificationDeepLinkActivationPolicy.shouldConsume(sceneIsActive: false))
        XCTAssertTrue(AtriaNotificationDeepLinkActivationPolicy.shouldConsume(sceneIsActive: true))
    }

    func testInactiveSceneCannotConsumeRetainedRoute() throws {
        let inbox = AtriaNotificationDeepLinkInbox(notificationCenter: NotificationCenter())
        let journal = try XCTUnwrap(URL(string: "atria://journal"))

        XCTAssertTrue(inbox.enqueue(journal, responseKey: "cold-launch|default"))
        XCTAssertNil(inbox.consume(sceneIsActive: false))
        XCTAssertEqual(inbox.consume(sceneIsActive: true), journal)
        XCTAssertNil(inbox.consume(sceneIsActive: true))
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

    func testNotificationResponseDoesNotWaitForMainActorBeforeReturning() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/LocalNotificationScheduler.swift"), encoding: .utf8)
        let handlerStart = try XCTUnwrap(source.range(of: "func userNotificationCenter(_ center: UNUserNotificationCenter,\n                                didReceive response:"))
        let handlerSuffix = source[handlerStart.lowerBound...]
        let handlerEnd = try XCTUnwrap(handlerSuffix.range(of: "\n    static func resolvedDeepLink"))
        let handler = handlerSuffix[..<handlerEnd.lowerBound]

        XCTAssertTrue(handler.contains("AtriaNotificationDeepLinkInbox.shared.enqueue"))
        XCTAssertFalse(handler.contains("await MainActor.run"))
    }
}
