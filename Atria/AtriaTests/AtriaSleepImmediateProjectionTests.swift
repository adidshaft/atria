import Combine
import XCTest
@testable import Atria

final class AtriaSleepImmediateProjectionTests: XCTestCase {
    private func confirmedSleep(
        start: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
        duration: TimeInterval = 8 * 60 * 60,
        source: String = "manual_sleep",
        motionSource: String = "manual",
        motionValidated: Bool = false,
        stages: [SleepStageSegment]? = nil
    ) -> UserConfirmedSleep {
        UserConfirmedSleep(id: "sleep-fixture",
                           createdAt: start.addingTimeInterval(duration),
                           start: start,
                           end: start.addingTimeInterval(duration),
                           source: source,
                           confidence: "manual_user_entered",
                           sessions: 1,
                           samples: 1_000,
                           avgHR: 60,
                           peakHR: 90,
                           restingHR: 52,
                           hrv: 48,
                           hrvWindowCount: 4,
                           duration: duration,
                           span: duration,
                           reason: "fixture",
                           motionSource: motionSource,
                           motionValidated: motionValidated,
                           stageSegments: stages,
                           eventTimeZoneIdentifier: "UTC")
    }

    func testConfirmedSleepSavePublishesLightweightSnapshotBeforeDeferredHistory() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func saveConfirmedSleeps("))
        let end = try XCTUnwrap(
            source.range(of: "private func writeDutyCycleSleepWindow", range: start.upperBound..<source.endIndex)
        )
        let savePath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(savePath.contains("setCachedConfirmedSleeps(sorted)"))
        XCTAssertTrue(savePath.contains("sleepHistorySnapshot = SleepHistorySnapshot("))
        XCTAssertTrue(savePath.contains("confirmedSleeps: sorted"))
        let publicationIndex = try XCTUnwrap(
            savePath.range(of: "sleepHistorySnapshot = SleepHistorySnapshot(")?.lowerBound
        )
        let deferredRefreshIndex = try XCTUnwrap(
            savePath.range(of: "refreshHistorySnapshotCache(deferred: true)")?.lowerBound
        )
        XCTAssertTrue(publicationIndex < deferredRefreshIndex)
    }

    func testDashboardRevisionSchedulesWidgetRefreshWithoutRelaunch() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: ".onReceive(store.$dashboardRevision.throttle")
        )
        let end = try XCTUnwrap(
            source.range(of: ".onReceive(NotificationCenter.default.publisher",
                         range: start.upperBound..<source.endIndex)
        )
        let dashboardHandler = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(dashboardHandler.contains("scheduleWidgetSnapshot(reason: \"dashboard_revision\")"))
    }

    func testDeferredLaunchSettlementRejectsGreyOrStaleRowsAndAcceptsCoherentCards() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let sleep = confirmedSleep()
        let day = calendar.startOfDay(for: sleep.end)
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 71,
                                      recoveryConfidence: "personal_baseline",
                                      hrv: sleep.hrv,
                                      restingHR: sleep.restingHR,
                                      respiratoryRate: 15.2,
                                      sleepDuration: sleep.duration,
                                      sleepSpan: sleep.span,
                                      sleepStart: sleep.start,
                                      sleepEnd: sleep.end,
                                      sleepSource: sleep.source,
                                      sleepStageSegments: sleep.stageSegments ?? [],
                                      sleepConsistencyPercent: 84,
                                      strain: 3.4)
        let settled = DailyRollupStoreEntry(day: day,
                                            recovery: 71,
                                            lnRMSSD: sleep.hrv.map { log(Double($0)) },
                                            rhr: sleep.restingHR,
                                            sleepSeconds: sleep.duration,
                                            sleepPerformance: 93,
                                            bedtimeMinutes: 1_320,
                                            strain: 3.4,
                                            calendar: calendar)

        XCTAssertTrue(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: metric,
            rollup: settled,
            calendar: calendar
        ))

        let grey = DailyRollupStoreEntry(day: day, calendar: calendar)
        XCTAssertFalse(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: metric,
            rollup: grey,
            calendar: calendar
        ), "an old all-nil rollup must never authorize launch/widget publication")

        let staleMetric = SavedDailyMetric(day: day,
                                           recoveryPercent: 71,
                                           recoveryConfidence: "personal_baseline",
                                           hrv: sleep.hrv,
                                           restingHR: sleep.restingHR,
                                           respiratoryRate: 15.2,
                                           sleepDuration: sleep.duration - 60 * 60,
                                           sleepSpan: sleep.span,
                                           sleepStart: sleep.start.addingTimeInterval(60 * 60),
                                           sleepEnd: sleep.end,
                                           sleepSource: sleep.source,
                                           sleepStageSegments: [],
                                           sleepConsistencyPercent: 84,
                                           strain: 3.4)
        XCTAssertFalse(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: sleep,
            metric: staleMetric,
            rollup: settled,
            calendar: calendar
        ), "a prior sleep boundary must not be published for the confirmed night")
    }

    func testDeferredLaunchSettlementUsesCanonicalFinalWakeForLinkedResumedSleep() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let main = confirmedSleep(duration: 4 * 60 * 60, source: "overnight_sleep")
        let resumedStart = main.end.addingTimeInterval(30 * 60)
        let resumedDuration: TimeInterval = 2 * 60 * 60
        let resumed = UserConfirmedSleep(
            id: "resumed-fixture",
            createdAt: resumedStart.addingTimeInterval(resumedDuration),
            start: resumedStart,
            end: resumedStart.addingTimeInterval(resumedDuration),
            source: "resumed_sleep",
            confidence: "manual_user_entered",
            sessions: 1,
            samples: 800,
            avgHR: 58,
            peakHR: 82,
            restingHR: 50,
            hrv: 51,
            hrvWindowCount: 3,
            duration: resumedDuration,
            span: resumedDuration,
            reason: "fixture",
            motionSource: "manual",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
        let canonical = try XCTUnwrap(AtriaPhysiologicalCycle.latestCompletedMainSleep(
            now: resumed.end.addingTimeInterval(60),
            confirmedSleeps: [main, resumed]
        ))
        let day = calendar.startOfDay(for: canonical.end)
        let metric = SavedDailyMetric(
            day: day,
            recoveryPercent: 39,
            recoveryConfidence: "unverified",
            hrv: canonical.hrv,
            restingHR: canonical.restingHR,
            respiratoryRate: 15.2,
            sleepDuration: canonical.duration,
            sleepSpan: canonical.span,
            sleepStart: canonical.start,
            sleepEnd: canonical.end,
            sleepSource: canonical.source,
            sleepStageSegments: canonical.stageSegments ?? [],
            sleepConsistencyPercent: 72,
            strain: 6.2
        )
        let rollup = DailyRollupStoreEntry(
            day: day,
            recovery: 39,
            lnRMSSD: canonical.hrv.map { log(Double($0)) },
            rhr: canonical.restingHR,
            sleepSeconds: canonical.duration,
            sleepPerformance: 68,
            bedtimeMinutes: 1_320,
            strain: 6.2,
            calendar: calendar
        )

        XCTAssertEqual(canonical.id, main.id)
        XCTAssertEqual(canonical.end, resumed.end)
        XCTAssertTrue(SessionStore.deferredLaunchCardSettlementMatches(
            sleep: canonical,
            metric: metric,
            rollup: rollup,
            calendar: calendar
        ))
    }

    func testDeferredLoadPublishesWidgetOnlyAfterVerifiedCardSettlement() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let sessions = try String(contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
                                  encoding: .utf8)
        let app = try String(contentsOf: appDirectory.appendingPathComponent("AtriaApp.swift"),
                             encoding: .utf8)
        let finishStart = try XCTUnwrap(sessions.range(of: "private func finishDeferredLoad("))
        let finishEnd = try XCTUnwrap(sessions.range(of: "private func continueDeferredLoadFollowUp",
                                                     range: finishStart.upperBound..<sessions.endIndex))
        let finish = String(sessions[finishStart.lowerBound..<finishEnd.lowerBound])
        let fence = try XCTUnwrap(finish.range(of: "deferredLaunchCardSettlementPending = true"))
        let loaded = try XCTUnwrap(finish.range(of: "self.hasCompletedDeferredSessionLoad = true"))
        let earlyDashboard = try XCTUnwrap(finish.range(of: "publishDashboardRevision()"))
        XCTAssertTrue(fence.lowerBound < loaded.lowerBound)
        XCTAssertTrue(loaded.lowerBound < earlyDashboard.lowerBound,
                      "the early UI revision is safe only because the widget fence is already active")

        let followUpStart = try XCTUnwrap(sessions.range(of: "private func continueDeferredLoadFollowUp"))
        let followUpEnd = try XCTUnwrap(sessions.range(of: "nonisolated static func deferredLaunchCardSettlementMatches",
                                                       range: followUpStart.upperBound..<sessions.endIndex))
        let followUp = String(sessions[followUpStart.lowerBound..<followUpEnd.lowerBound])
        XCTAssertTrue(followUp.contains("resumeDeferredLaunchCardSettlementIfNeeded(reason: \"deferred_session_load\")"))
        XCTAssertFalse(followUp.contains("refreshHistorySnapshotCache(deferred: true)"),
                       "launch must use the inherited required-publication fence")

        let requestStart = try XCTUnwrap(sessions.range(of: "private func requestDeferredLaunchCardSettlement("))
        let requestBody = String(sessions[requestStart.lowerBound...].prefix(8_000))
        let persistedFastPath = try XCTUnwrap(requestBody.range(
            of: "status=published_fast_path"
        ))
        let historicalRefresh = try XCTUnwrap(requestBody.range(
            of: "requestRequiredHistorySnapshotRefresh(deferred: true)"
        ))
        XCTAssertLessThan(
            persistedFastPath.lowerBound,
            historicalRefresh.lowerBound,
            "coherent persisted cards must not wait on the historical archive projection"
        )
        let verification = try XCTUnwrap(requestBody.range(of: "deferredLaunchCardSettlementMatches"))
        let dashboard = try XCTUnwrap(requestBody.range(of: "self.publishDashboardRevision()",
                                                        range: verification.upperBound..<requestBody.endIndex))
        let handoff = try XCTUnwrap(requestBody.range(of: "self.onDeferredLaunchCardSettlementPublished?(reason)",
                                                      range: dashboard.upperBound..<requestBody.endIndex))
        XCTAssertTrue(verification.lowerBound < dashboard.lowerBound)
        XCTAssertTrue(dashboard.lowerBound < handoff.lowerBound)
        XCTAssertTrue(requestBody.contains("status=withheld"),
                      "mismatched rows must retain the last durable widget snapshot")
        let clearFence = try XCTUnwrap(requestBody.range(
            of: "self.deferredLaunchCardSettlementPending = false",
            range: verification.upperBound..<requestBody.endIndex
        ))
        XCTAssertTrue(verification.lowerBound < clearFence.lowerBound)
        XCTAssertTrue(clearFence.lowerBound < dashboard.lowerBound)

        XCTAssertTrue(app.contains("store.onDeferredLaunchCardSettlementPublished ="))
        XCTAssertTrue(app.contains("reason: \"deferred_launch_cards_\\(reason)\""))
        XCTAssertTrue(app.contains("delay: .zero"))
    }

    func testNoSleepFallbackReleasesWidgetFenceFromCurrentRecoveryAuthority() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let sessions = try String(
            contentsOf: appDirectory.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        let requestStart = try XCTUnwrap(
            sessions.range(of: "private func requestDeferredLaunchCardSettlement(")
        )
        let requestBody = String(sessions[requestStart.lowerBound...].prefix(10_000))
        let requiredRefresh = try XCTUnwrap(
            requestBody.range(of: "requestRequiredHistorySnapshotRefresh(")
        )
        let fallback = try XCTUnwrap(
            requestBody.range(of: "physiologicalCycle.boundaryKind != .mainSleep")
        )
        let resolver = try XCTUnwrap(
            requestBody.range(
                of: "DailyRecoveryResolver.summary(",
                range: fallback.upperBound..<requestBody.endIndex
            )
        )
        let release = try XCTUnwrap(
            requestBody.range(
                of: "deferredLaunchCardSettlementPending = false",
                range: resolver.upperBound..<requestBody.endIndex
            )
        )
        XCTAssertTrue(fallback.lowerBound < resolver.lowerBound)
        XCTAssertTrue(resolver.lowerBound < release.lowerBound)
        XCTAssertTrue(release.lowerBound < requiredRefresh.lowerBound,
                      "a current strict fallback must not wait behind the history worker")
        XCTAssertTrue(requestBody.contains("_fallback_recovery"))
    }

    func testWidgetPersistenceWaitsForBothSessionLoadAndCardSettlement() {
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: false,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: false
        ))
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: false,
            deferredLaunchCardSettlementPending: false
        ), "a provisional live Recovery must not replace persisted authority")
        XCTAssertFalse(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: true
        ), "the sessions-landed UI revision must not persist stale grey cards")
        XCTAssertTrue(WidgetSnapshotPublisher.shouldPersistSnapshot(
            hasLoadedSavedSessions: true,
            hasLoadedRecoveryHistory: true,
            deferredLaunchCardSettlementPending: false
        ))
    }

    func testDeferredLaunchCardSettlementRetryIsStrictlyBounded() {
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 0), 250)
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 1), 500)
        XCTAssertNil(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 2))
        XCTAssertNil(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: 100))
        XCTAssertEqual(SessionStore.deferredLaunchCardSettlementRetryDelay(afterFailedAttempt: -1), 250)
    }

    func testRecoveryShowsLimitedConfidenceScoreWithoutQualifiedCurrentHRV() {
        let now = Date()
        var baseline = PersonalBaseline()
        for dayOffset in 1...3 {
            baseline.learn(fromResting: 56,
                           hrv: 48 + dayOffset,
                           at: now.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                           overnight: true)
        }

        let recovery = Metrics.recoveryV2(
            hrvSnapshot: nil,
            fallbackRMSSD: nil,
            restingNow: 54,
            baseline: baseline,
            sleepEfficiency: 0.9,
            sleepDurationHours: 6.1
        )
        XCTAssertNotNil(recovery.percent,
                        "measured sleep must produce an honestly labeled day-one estimate")
        XCTAssertEqual(recovery.confidence, .unverified)
        XCTAssertFalse(recovery.usesHRV)
        XCTAssertTrue(recovery.detail.contains("HRV unavailable"))
        XCTAssertEqual(recovery.contributors.first(where: { $0.kind == .hrv })?.weight, 0)
    }

    func testStageAndMotionOnlySleepRepairCannotTriggerBaselineReplay() {
        let original = confirmedSleep()
        let stage = SleepStageSegment(id: "light",
                                      start: original.start,
                                      end: original.end,
                                      stage: .light)
        let repaired = confirmedSleep(motionSource: "historical_gravity",
                                      motionValidated: true,
                                      stages: [stage])

        XCTAssertFalse(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [repaired]
        ))
    }

    func testConfirmedMainSleepBoundaryChangeStillTriggersBaselineReplay() {
        let original = confirmedSleep()
        let shifted = confirmedSleep(start: original.start.addingTimeInterval(30 * 60))

        XCTAssertTrue(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [shifted]
        ))
    }

    func testSleepReclassificationStillTriggersBaselineReplay() {
        let original = confirmedSleep()
        let nap = confirmedSleep(duration: 60 * 60, source: "manual_nap")

        XCTAssertTrue(SessionStore.confirmedSleepMutationAffectsBaseline(
            previous: [original],
            next: [nap]
        ))
    }

    @MainActor
    func testCorrectedSleepSaveSettlesTodayRecoveryStrainAndWidgetInProcess() async throws {
        let now = Date()
        let correctedEnd = now.addingTimeInterval(-45 * 60)
        let correctedStart = correctedEnd.addingTimeInterval(-(5 * 60 * 60 + 35 * 60))
        let wrongStart = correctedStart.addingTimeInterval(-(2 * 60 * 60 + 44 * 60))
        let wrongEnd = correctedEnd.addingTimeInterval(-60 * 60)
        let rollover = correctedStart.addingTimeInterval(3 * 60 * 60)
        let sleepSessions = [
            physiologicalSession(start: correctedStart,
                                 end: rollover,
                                 restingBPM: 54),
            physiologicalSession(start: rollover,
                                 end: correctedEnd,
                                 restingBPM: 54)
        ]
        let activityStart = correctedEnd.addingTimeInterval(10 * 60)
        let activityEnd = now.addingTimeInterval(-5 * 60)
        let activitySession = elevatedSession(start: activityStart, end: activityEnd)
        let store = makeStore(now: now)
        for session in sleepSessions {
            XCTAssertTrue(store.add(session))
        }
        XCTAssertTrue(store.add(activitySession))
        defer {
            for session in sleepSessions {
                store.deleteSession(id: session.id)
            }
            store.deleteSession(id: activitySession.id)
        }

        let today = AtriaTodaySessionProjectionStore(store: store)
        let review = SleepHistorySnapshot.Night(
            id: "wrong-pending-\(UUID().uuidString)",
            day: Calendar.current.startOfDay(for: wrongEnd),
            start: wrongStart,
            end: wrongEnd,
            duration: wrongEnd.timeIntervalSince(wrongStart),
            restingHR: 54,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: nil,
            sleepEfficiency: 0.9,
            confidence: "review_needed",
            source: "sleep_episode_review",
            confirmed: false,
            stageSegments: [],
            eventTimeZoneIdentifier: TimeZone.current.identifier
        )
        let priorDashboardRevision = store.dashboardRevision
        let publication = expectation(description: "Today receives confirmed sleep")
        var cancellable: AnyCancellable?
        cancellable = today.$state.dropFirst().sink { state in
            if state.sleepHistorySnapshot.latestMainSleep?.confirmed == true {
                publication.fulfill()
            }
        }

        let saved = try XCTUnwrap(store.saveSleepReviewNightForUI(
            review,
            start: correctedStart,
            end: correctedEnd,
            isNap: false,
            rest: 55,
            source: "post_sleep_cards_regression"
        ))
        defer { _ = store.deleteConfirmedSleep(id: saved.id) }

        await fulfillment(of: [publication], timeout: 2)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(saved.start, correctedStart)
        XCTAssertEqual(saved.end, correctedEnd)
        XCTAssertEqual(saved.sessions, sleepSessions.count,
                       "the corrected sleep must be assembled across persisted three-hour rollovers")
        XCTAssertGreaterThan(saved.duration, 5 * 60 * 60)
        XCTAssertNotNil(saved.hrv, "qualified RR in the corrected window must survive the edit")
        XCTAssertGreaterThan(saved.hrvWindowCount ?? 0, 2)
        XCTAssertGreaterThan(store.dashboardRevision, priorDashboardRevision,
                             "the same process must publish the widget/dashboard trigger")

        let projectedSleep = try XCTUnwrap(today.state.sleepHistorySnapshot.latestMainSleep)
        XCTAssertEqual(projectedSleep.id, saved.id)
        XCTAssertTrue(projectedSleep.confirmed)
        XCTAssertEqual(projectedSleep.duration, saved.duration, accuracy: 0.1)
        let performance = today.state.sleepHistorySnapshot.sleepPerformancePercent(
            for: projectedSleep,
            baseNeedHours: SessionStore.configuredSleepBaseNeedHours()
        )
        XCTAssertGreaterThan(performance, 0)

        let recovery = store.recoveryProjection(now: now,
                                                initialFallbackHRVSnapshot: nil,
                                                liveRestingHeartRate: nil)
        XCTAssertNotNil(recovery.percent,
                        "qualified sleep HRV + RHR + a learned baseline must produce an honest score")
        XCTAssertTrue(recovery.usesHRV)

        let aggregate = store.homeSavedAggregate(rest: saved.restingHR,
                                                 maxHR: store.profile.maxHR,
                                                 now: now)
        let strain = Metrics.strain(fromTRIMP: aggregate.savedTodayTRIMP)
        XCTAssertGreaterThan(strain, 0, "post-wake activity strain must remain real after sleep changes the cycle")
        let strainFill = try XCTUnwrap(AtriaRingMetricProjection.strainFill(strain: strain))
        XCTAssertGreaterThan(strainFill, 0)
        XCTAssertEqual(AtriaRingMetricProjection.strainTint(targetProgress: nil,
                                                            actualFill: strainFill),
                       Metrics.electricStrain,
                       "missing Recovery target must not make measured strain look absent")

        let ble = AtriaBLEManager(startsBluetooth: false)
        let widget = WidgetSnapshotPublisher.publish(store: store,
                                                     ble: ble,
                                                     reason: "post_sleep_cards_regression")
        XCTAssertEqual(widget.sleepHours ?? -1, saved.duration / 3_600, accuracy: 0.01)
        XCTAssertEqual(widget.recoveryPercent, recovery.percent)
        XCTAssertGreaterThan(widget.strain, 0)
        XCTAssertEqual(widget.strain, strain, accuracy: 0.05,
                       "widget and Today must remain on the same physiological-cycle strain")
    }

    @MainActor
    private func makeStore(now: Date) -> SessionStore {
        var baseline = PersonalBaseline()
        for dayOffset in 1...3 {
            baseline.learn(fromResting: 56,
                           hrv: 48 + dayOffset,
                           at: now.addingTimeInterval(-Double(dayOffset) * 24 * 60 * 60),
                           overnight: true)
        }
        let rollupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-post-sleep-cards-\(UUID().uuidString).json")
        return SessionStore(restoreInitialization: .init(
            recover: { .noMarker },
            loadBaseline: { baseline },
            loadProfile: {
                AthleteProfile(age: 30,
                               measuredMaxHR: 190,
                               maxHRSource: .measured,
                               updated: now,
                               hasCompletedOnboarding: true)
            },
            loadDailyRollups: {
                DailyRollupStore(url: rollupURL,
                                 recoveryMetricsURL: nil,
                                 loadPersisted: false)
            }
        ))
    }

    private func physiologicalSession(start: Date,
                                      end: Date,
                                      restingBPM: Int) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, through: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: restingBPM + (Int($0 / 60).isMultiple(of: 7) ? 1 : 0))
        }
        var session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Post-sleep card RR fixture",
                                   points: points,
                                   eventTimeZoneIdentifier: TimeZone.current.identifier)
        session.rrPoints = stride(from: 0.0, through: duration, by: 1.0).map {
            SavedSession.RRPoint(t: $0,
                                 ms: Int($0).isMultiple(of: 2) ? 920 : 1_040,
                                 source: .standardHeartRateMeasurement2A37)
        }
        return session
    }

    private func elevatedSession(start: Date, end: Date) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Post-wake strain fixture",
                            points: stride(from: 0.0, through: duration, by: 1.0).map {
                                SavedSession.Point(t: $0, bpm: 138)
                            },
                            kind: "workout",
                            eventTimeZoneIdentifier: TimeZone.current.identifier)
    }
}
