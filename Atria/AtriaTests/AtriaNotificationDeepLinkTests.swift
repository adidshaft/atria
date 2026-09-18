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

    func testMetricDeepLinkOpensTheSameSheetAsATodayTap() throws {
        let hrv = try XCTUnwrap(AtriaMetricDeepLink.parse(URL(string: "atria://metric/hrv")!))
        XCTAssertEqual(hrv.metric, .hrv)
        XCTAssertEqual(hrv.range, .day)

        let week = try XCTUnwrap(AtriaMetricDeepLink.parse(URL(string: "atria://metric/hrv?range=week")!))
        XCTAssertEqual(week.metric, .hrv)
        XCTAssertEqual(week.range, .week)

        let monthRHR = try XCTUnwrap(AtriaMetricDeepLink.parse(URL(string: "atria://metric/rhr?range=month")!))
        XCTAssertEqual(monthRHR.metric, .restingHeartRate)
        XCTAssertEqual(monthRHR.range, .month)

        XCTAssertNil(AtriaMetricDeepLink.parse(URL(string: "atria://tab/vitals")!))
        XCTAssertNil(AtriaMetricDeepLink.parse(URL(string: "atria://sleep-review")!))

        let weekRoute = AtriaMetricSheetRoute(metric: .hrv, range: .week)
        XCTAssertEqual(weekRoute.id, "hrv-week")
        XCTAssertNotEqual(weekRoute.id, AtriaMetricSheetRoute(metric: .hrv, range: .day).id)
    }

    func testPendingDeepLinkFileOpensTheSameURLAsOnOpenURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-pending-deeplink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AtriaPendingDeepLinkFile.documentsDirectoryOverride = directory
        defer {
            AtriaPendingDeepLinkFile.documentsDirectoryOverride = nil
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(AtriaPendingDeepLinkFile.consume())
        try "atria://metric/hrv?range=week".write(
            to: AtriaPendingDeepLinkFile.fileURL(),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            AtriaPendingDeepLinkFile.consume(),
            URL(string: "atria://metric/hrv?range=week")
        )
        XCTAssertNil(AtriaPendingDeepLinkFile.consume())
        XCTAssertFalse(FileManager.default.fileExists(atPath: AtriaPendingDeepLinkFile.fileURL().path))
    }

    func testSleepMetricDeepLinkIsNotSwallowedBySleepReview() throws {
        let sleep = try XCTUnwrap(AtriaMetricDeepLink.parse(URL(string: "atria://metric/sleep?range=week")!))
        XCTAssertEqual(sleep.metric, .sleep)
        XCTAssertEqual(sleep.range, .week)

        let home = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("if pieces.first == \"metric\" { return false }"),
                      "atria://metric/sleep must open the Sleep trend sheet")
        XCTAssertTrue(home.contains("AtriaMetricDeepLink.parse(url)"))
        let metricIndex = try XCTUnwrap(home.range(of: "if let metricLink = AtriaMetricDeepLink.parse(url)"))
        let sleepReviewIndex = try XCTUnwrap(home.range(of: "if Self.isSleepReviewDeepLink(url)"))
        XCTAssertTrue(metricIndex.lowerBound < sleepReviewIndex.lowerBound,
                      "metric/sleep must be claimed before the sleep-review token matcher")
    }

    func testWorkoutDeepLinkStartsAndEndsARunningWorkout() throws {
        let start = try XCTUnwrap(AtriaWorkoutDeepLink.parse(URL(string: "atria://workout/start")!))
        XCTAssertEqual(start.action, .start)
        XCTAssertEqual(start.activityType, .running)

        let walking = try XCTUnwrap(AtriaWorkoutDeepLink.parse(URL(string: "atria://workout/start?type=walking")!))
        XCTAssertEqual(walking.activityType, .walking)

        let end = try XCTUnwrap(AtriaWorkoutDeepLink.parse(URL(string: "atria://workout/end")!))
        XCTAssertEqual(end.action, .end)

        let dismiss = try XCTUnwrap(AtriaWorkoutDeepLink.parse(URL(string: "atria://workout/dismiss")!))
        XCTAssertEqual(dismiss.action, .dismiss)

        let minimize = try XCTUnwrap(AtriaWorkoutDeepLink.parse(URL(string: "atria://workout/minimize")!))
        XCTAssertEqual(minimize.action, .minimize)

        XCTAssertNil(AtriaWorkoutDeepLink.parse(URL(string: "atria://metric/hrv")!))
        XCTAssertNil(AtriaWorkoutDeepLink.parse(URL(string: "atria://overview")!))

        let home = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("pendingWorkoutDeepLink"))
        XCTAssertTrue(home.contains("await handleWorkoutDeepLink(command)"))
        XCTAssertTrue(home.contains("beginWorkoutSession(configuration: .init(activityType: command.activityType))"))
        XCTAssertTrue(home.contains("dismissPresentedWorkoutChrome()"),
                      "metric, widget, and workout start links must drop the saved-workout recap so the next sheet can present")
        XCTAssertTrue(home.contains("case .dismiss:"),
                      "atria://workout/dismiss must clear the recap without starting another session")
        XCTAssertTrue(home.contains("showLiveActivityLockPreview = false"),
                      "end and dismiss must drop the lock-preview sheet so it cannot stick after a run")
        XCTAssertTrue(home.contains("workoutEndNotice = nil"))
        XCTAssertTrue(home.contains("showWidgetOvernightBoard = false"),
                      "a metric deep link must drop the widget payload board so Day/Week/Month can present")
        XCTAssertTrue(home.contains("isLiveActivityLockPreviewDeepLink"))
        XCTAssertTrue(home.contains("pieces.first == \"live-activity\""))
        XCTAssertTrue(home.contains("AtriaLiveActivityLockPreviewSheet("))
        XCTAssertTrue(home.contains("case .minimize:"))
        let tabStart = try XCTUnwrap(home.range(of: "guard let tab = HomeTab.deepLinkDestination(for: url) else { return }"))
        let tabSlice = String(home[tabStart.lowerBound...].prefix(400))
        XCTAssertTrue(tabSlice.contains("dismissPresentedWorkoutChrome()"),
                      "Activity/Vitals/Journal deeplinks must drop the lock-preview sheet (device 157)")
    }

    func testWidgetBoardDeepLinkIsSeparateFromWidgetProofDiagnostics() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let board = try String(contentsOf: testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWidgetOvernightBoard.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("isWidgetOvernightBoardDeepLink"))
        XCTAssertTrue(home.contains("showWidgetOvernightBoard = true"))
        XCTAssertTrue(home.contains("pieces.first == \"widget-board\""))
        XCTAssertTrue(home.contains("pieces.first == \"widget-proof\""))
        XCTAssertFalse(home.contains("return pieces.first == \"widget-proof\" || pieces.first == \"widget-board\""))
        XCTAssertFalse(home.contains("deeplink_widget_board"),
                       "widget-board must print the already-published payload, not republish")
        XCTAssertTrue(home.contains("metricSheetDismissToken += 1"))
        XCTAssertTrue(board.contains("AtriaIntentSnapshotStore.loadPublishedPayload()"))
        XCTAssertTrue(board.contains(".onAppear"))
    }
}
