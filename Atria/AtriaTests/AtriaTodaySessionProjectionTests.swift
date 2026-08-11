import Combine
import XCTest
@testable import Atria

@MainActor
final class AtriaTodaySessionProjectionTests: XCTestCase {
    func testInactiveAuthorityRejectsQueuedCompletionAndPublishesLatestOnce() async {
        let sessionStore = SessionStore()
        await sessionStore.waitForDeferredSessionLoadIfNeeded()
        let originalProfile = sessionStore.profile
        var applicationIsActive = true
        let projection = AtriaTodaySessionProjectionStore(
            store: sessionStore,
            presentationIsActive: true,
            applicationIsActive: { applicationIsActive }
        )
        let originalMaxHeartRate = projection.state.maxHeartRate
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        let queuedMax = originalMaxHeartRate == 201 ? 202 : 201
        sessionStore.updateProfile {
            $0.maxHRSource = .measured
            $0.measuredMaxHR = queuedMax
        }
        projection.setPresentationActive(false)
        await Task.yield()
        await Task.yield()
        for _ in 0..<1_000 {
            _ = projection.refresh()
        }

        XCTAssertEqual(publications, 0)
        XCTAssertEqual(projection.state.maxHeartRate, originalMaxHeartRate,
                       "a queued foreground refresh must reject its inactive completion")

        applicationIsActive = false
        projection.setPresentationActive(true)
        for nextMax in [203, 204, 205] {
            sessionStore.updateProfile {
                $0.maxHRSource = .measured
                $0.measuredMaxHR = nextMax
            }
        }
        projection.setPresentationActive(true)
        await Task.yield()
        XCTAssertEqual(publications, 0,
                       "cached scene authority must still fail closed while UIApplication is inactive")

        applicationIsActive = true
        projection.setPresentationActive(true)
        XCTAssertEqual(projection.state.maxHeartRate, 205)
        XCTAssertEqual(publications, 1,
                       "the active edge publishes only the latest collapsed projection")
        await Task.yield()
        await Task.yield()
        projection.setPresentationActive(true)
        XCTAssertEqual(publications, 1,
                       "stale queued work and repeated active delivery cannot duplicate catch-up")

        projection.setPresentationActive(false)
        sessionStore.updateProfile { $0 = originalProfile }
        withExtendedLifetime(cancellable) {}
    }

    func testNoOpRefreshDoesNotPublish() {
        let sessionStore = SessionStore()
        let projection = AtriaTodaySessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refresh())
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testIrrelevantDashboardRevisionDoesNotPublishTodayProjection() {
        let sessionStore = SessionStore()
        let projection = AtriaTodaySessionProjectionStore(store: sessionStore)
        var publications = 0
        let cancellable = projection.objectWillChange.sink { publications += 1 }

        XCTAssertFalse(projection.refreshForDashboardRevision())
        XCTAssertEqual(publications, 0)
        withExtendedLifetime(cancellable) {}
    }

    func testTodayStateCarriesCivilDaySoMidnightClearsDayScopedCheckIn() {
        let sessionStore = SessionStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = Date(timeIntervalSince1970: 1_783_641_599)
        let afterMidnight = beforeMidnight.addingTimeInterval(2)

        let before = AtriaTodaySessionState(store: sessionStore,
                                            now: beforeMidnight,
                                            calendar: calendar)
        let after = AtriaTodaySessionState(store: sessionStore,
                                           now: afterMidnight,
                                           calendar: calendar)

        XCTAssertNotEqual(before.localDay, after.localDay)
        XCTAssertNotEqual(before, after)
    }

    func testRelevantProfileChangePublishesProjectedMaxHeartRate() async {
        let sessionStore = SessionStore()
        let originalProfile = sessionStore.profile
        let projection = AtriaTodaySessionProjectionStore(store: sessionStore)
        let nextMeasuredMax = originalProfile.measuredMaxHR == 211 ? 210 : 211
        let updated = expectation(description: "Today projection receives profile")
        let cancellable = projection.$state
            .dropFirst()
            .filter { $0.maxHeartRate == nextMeasuredMax }
            .prefix(1)
            .sink { _ in updated.fulfill() }

        sessionStore.updateProfile {
            $0.maxHRSource = .measured
            $0.measuredMaxHR = nextMeasuredMax
        }

        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(projection.state.maxHeartRate, nextMeasuredMax)
        // SessionStore finishes deferred persisted-state loading independently
        // of this profile publication. Fold in a legitimate late snapshot once,
        // then assert the projection has converged and no longer republishes.
        _ = projection.refresh()
        XCTAssertFalse(projection.refresh())

        sessionStore.updateProfile { $0 = originalProfile }
        withExtendedLifetime(cancellable) {}
    }

    func testTodayObservesNarrowStoresAndAvoidsBroadSessionObservation() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let screenStart = try XCTUnwrap(source.range(of: "struct AtriaTodayScreen: View"))
        let hostStart = try XCTUnwrap(source.range(of: "private struct AtriaTodayHeroProjectionHost<Content: View>"))
        let screenSource = String(source[screenStart.lowerBound..<hostStart.lowerBound])
        XCTAssertTrue(screenSource.contains("let heroStore: AtriaHomeModel.HeroStore"))
        XCTAssertFalse(screenSource.contains("@ObservedObject var heroStore: AtriaHomeModel.HeroStore"))
        XCTAssertTrue(source.contains("private struct AtriaTodayHeroProjectionHost<Content: View>: View, Equatable"))
        XCTAssertTrue(source.contains("@ObservedObject var heroStore: AtriaHomeModel.HeroStore"),
                      "Only the narrow hero leaf should own live HeroStore observation")
        XCTAssertTrue(source.contains("@ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore"))
        XCTAssertTrue(source.contains("@ObservedObject var sessionProjectionStore: AtriaTodaySessionProjectionStore"))
        XCTAssertFalse(source.contains("@ObservedObject var store: SessionStore"))
        XCTAssertTrue(source.contains("guard next != state else { return false }"))
    }

    func testInsightsTileUsesRankedBehaviorProjectionAndCanonicalCard() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let behaviorInsights: [AtriaInsight]"))
        XCTAssertTrue(source.contains("behaviorInsights = store.behaviorInsights"))
        XCTAssertTrue(source.contains("store.$behaviorInsights.dropFirst()"),
                      "Today must refresh when the ranked insight engine publishes")

        let insightCaseStart = try XCTUnwrap(source.range(of: "case .insights:"))
        let layoutSizeStart = try XCTUnwrap(
            source.range(of: "private func layoutSize(for metric:",
                         range: insightCaseStart.upperBound..<source.endIndex)
        )
        let insightCase = String(source[insightCaseStart.lowerBound..<layoutSizeStart.lowerBound])
        XCTAssertTrue(insightCase.contains("sessionProjectionStore.state.behaviorInsights"))
        XCTAssertTrue(insightCase.contains("value: \"\\(insights.count)\""))
        XCTAssertFalse(insightCase.contains("highlights.count"),
                       "The Insights tile must not count unrelated Today highlights")

        XCTAssertTrue(source.contains("showInsights = true"))
        XCTAssertTrue(source.contains("AtriaInsightsCardHost(store: store)"),
                      "Today should reuse the canonical ranked-insights card")
    }

    func testDayStrainIncompleteCacheReusesOnlyExactSourceWindow() {
        let day = Date(timeIntervalSince1970: 1_720_000_000)
        let key = AtriaTodayDayStrainIncompleteKey(confirmedWorkoutsRevision: 7,
                                                   day: day)
        var cache = AtriaTodayDayStrainIncompleteCache()
        var computations = 0

        XCTAssertTrue(cache.resolve(key: key) {
            computations += 1
            return true
        })
        XCTAssertTrue(cache.resolve(key: key) {
            computations += 1
            return false
        })
        XCTAssertEqual(computations, 1)

        let newRevision = AtriaTodayDayStrainIncompleteKey(confirmedWorkoutsRevision: 8,
                                                           day: day)
        XCTAssertFalse(cache.resolve(key: newRevision) {
            computations += 1
            return false
        })
        XCTAssertEqual(computations, 2)

        let noLongerLow = AtriaTodayDayStrainIncompleteKey(confirmedWorkoutsRevision: 8,
                                                           day: day)
        XCTAssertFalse(cache.resolve(key: noLongerLow) {
            computations += 1
            return false
        })
        XCTAssertEqual(computations, 2)
    }

    func testBroadDashboardSignalIsRevisionGatedBeforeTodaySnapshotRebuild() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let storeStart = try XCTUnwrap(
            source.range(of: "final class AtriaTodaySessionProjectionStore: ObservableObject")
        )
        let screenStart = try XCTUnwrap(
            source.range(of: "struct AtriaTodayScreen: View", range: storeStart.upperBound..<source.endIndex)
        )
        let projectionStore = String(source[storeStart.lowerBound..<screenStart.lowerBound])

        XCTAssertTrue(projectionStore.contains("store.$dashboardRevision"))
        XCTAssertTrue(projectionStore.contains("refreshForDashboardRevision()"))
        XCTAssertTrue(projectionStore.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertTrue(projectionStore.contains("presentationIsActive && applicationIsActive()"))
        XCTAssertTrue(projectionStore.contains("guard self.presentationIsAuthorized,"),
                      "queued Today completions must recheck live scene/app authority")
        XCTAssertTrue(projectionStore.contains("presentationIsDirty = true"))
        XCTAssertTrue(projectionStore.contains("store.confirmedWorkoutsRevision != state.confirmedWorkoutsRevision"))
        XCTAssertTrue(projectionStore.contains("store.behaviorJournalRevision != state.behaviorJournalRevision"))
        XCTAssertFalse(projectionStore.contains("store.$dailyMetricHistory"),
                       "Today does not project dailyMetricHistory, so that publisher must not trigger a full snapshot rebuild")
    }
}
