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

    @MainActor
    func testOrdinaryProductionLaunchIncludesReviewDecisions() {
        let scope = LocalNotificationScheduler.launchDecisionScope(arguments: [])
        XCTAssertTrue(scope.productionCadence)
        XCTAssertTrue(scope.includeSleepReviewDecisions)
        XCTAssertTrue(scope.includeWorkoutReviewDecisions)
    }

    func testWorkoutReviewDeliveryReservationIsExactlyOncePerCandidate() {
        XCTAssertTrue(LocalNotificationScheduler.workoutReviewDeliveryCanReserve(
            candidateID: "effort-1",
            lastNotifiedCandidateID: nil,
            inFlightCandidateIDs: []
        ))
        XCTAssertFalse(LocalNotificationScheduler.workoutReviewDeliveryCanReserve(
            candidateID: "effort-1",
            lastNotifiedCandidateID: "effort-1",
            inFlightCandidateIDs: []
        ))
        XCTAssertFalse(LocalNotificationScheduler.workoutReviewDeliveryCanReserve(
            candidateID: "effort-1",
            lastNotifiedCandidateID: nil,
            inFlightCandidateIDs: ["effort-1"]
        ))
        XCTAssertTrue(LocalNotificationScheduler.workoutReviewDeliveryCanReserve(
            candidateID: "effort-2",
            lastNotifiedCandidateID: "effort-1",
            inFlightCandidateIDs: ["effort-1"]
        ))
    }

    func testOrdinaryAppLifecycleReachesProductionNotificationMaintenance() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaApp.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("scheduleProductionNotificationMaintenance(reason: fastLaunchReason"))
        XCTAssertTrue(source.contains("scheduleProductionNotificationMaintenance(reason: \"scene_active\")"))
        XCTAssertTrue(source.contains("await store.waitForDeferredSessionLoadIfNeeded()"))
        XCTAssertTrue(source.contains("LocalNotificationScheduler.scheduleFromLaunchIfRequested(store: store,"))
    }

    func testWorkoutReviewCachePublicationRetriesNotificationWithoutClearingPendingRequests() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let scheduler = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/LocalNotificationScheduler.swift"), encoding: .utf8)

        let dashboardStart = try XCTUnwrap(home.range(
            of: ".onReceive(store.$dashboardRevision.throttle"
        ))
        let dashboardHandler = String(home[dashboardStart.lowerBound...].prefix(200))
        // 6eafc7bc moved the closure body verbatim into a named handler to keep
        // the SwiftUI body type-checkable; follow the dispatch instead of
        // re-pinning an inline closure.
        XCTAssertTrue(dashboardHandler.contains("handleDashboardRevisionUpdate()"),
                      "dashboard publication must drive the review-candidate refresh")
        let dashboardUpdateStart = try XCTUnwrap(home.range(
            of: "private func handleDashboardRevisionUpdate()"
        ))
        let dashboardUpdate = String(home[dashboardUpdateStart.lowerBound...].prefix(600))
        XCTAssertTrue(dashboardUpdate.contains(
            "refreshSavedWorkoutReviewCandidate(reason: \"dashboard_revision\")"
        ))
        XCTAssertTrue(dashboardUpdate.contains(
            "scheduleWorkoutReviewAfterCachePublicationIfNeeded"
        ), "the async review-cache publication must receive one delivery retry")

        let retryStart = try XCTUnwrap(scheduler.range(
            of: "static func scheduleWorkoutReviewAfterCachePublicationIfNeeded"
        ))
        let retryBody = String(scheduler[retryStart.lowerBound...].prefix(3_600))
        XCTAssertFalse(retryBody.contains("removePendingNotificationRequests"),
                       "a cache retry must not clear sleep, battery, or other pending notifications")
        XCTAssertTrue(retryBody.contains("candidate.id != defaults.string(forKey: workoutReviewLastCandidateIDKey)"))
        XCTAssertTrue(scheduler.contains("workoutReviewCandidateIDsInFlight.insert(workoutCandidateID).inserted"),
                      "launch maintenance and cache retry must share one in-flight reservation")
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

    func testColdCacheSleepReviewRouteWaitsForResolvedCandidate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let sessions = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)

        XCTAssertTrue(sessions.contains("enum SleepReviewResolution: Equatable"))
        XCTAssertTrue(sessions.contains("case loading"))
        XCTAssertTrue(sessions.contains("case ready(SleepHistorySnapshot.Night?)"))
        XCTAssertTrue(home.contains("@State private var pendingSleepReviewDeepLink = false"))
        XCTAssertTrue(home.contains(".onReceive(store.$pendingSleepReviewNightForUI)"))
        XCTAssertTrue(home.contains("resolvePendingSleepReviewDeepLinkIfNeeded(publishedNight: night)"))
        XCTAssertTrue(home.contains("if let night = publishedNight"))
        XCTAssertTrue(home.contains("case .loading:\n                pendingSleepReviewDeepLink = true"))
        XCTAssertFalse(home.contains("AtriaSleepReviewSheetRoute(night: night)\n            AtriaDebugLog"),
                       "A cache miss must not immediately present a nil-night Add Sleep route")
    }
}
