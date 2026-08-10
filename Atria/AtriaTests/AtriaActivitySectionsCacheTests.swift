import XCTest
import UIKit
@testable import Atria

final class AtriaActivitySectionsCacheTests: XCTestCase {
    func testActivityTimelineRefreshPolicyUsesOnlySceneReentryBoundaries() {
        XCTAssertTrue(AtriaActivityTimelineRefreshPolicy.shouldRefresh(
            previousScenePhase: .background,
            scenePhase: .active
        ))
        XCTAssertTrue(AtriaActivityTimelineRefreshPolicy.shouldRefresh(
            previousScenePhase: .inactive,
            scenePhase: .active
        ))
        XCTAssertFalse(AtriaActivityTimelineRefreshPolicy.shouldRefresh(
            previousScenePhase: .active,
            scenePhase: .inactive
        ))
        XCTAssertFalse(AtriaActivityTimelineRefreshPolicy.shouldRefresh(
            previousScenePhase: .active,
            scenePhase: .active
        ))
        XCTAssertEqual(AtriaActivityTimelineRefreshPolicy.nextRevision(after: 41), 42)
    }

    func testActivityTimelineRefreshesAfterSettledArchivePublicationNotEveryRawRow() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("SessionStore.recoveredDataRecomputeDidPublishNotification"))
        XCTAssertTrue(source.contains("completenessRevision: timelineCompletenessRevision"))
        XCTAssertFalse(source.contains(
            "publisher(for: HistoricalArchive.didUpdateNotification)"
        ), "Per-row archive writes must not trigger repeated whole-day scans")
        XCTAssertTrue(source.contains("sessions: window.isCurrentPhysiologicalDay ? store.sessions : []"),
                      "The current wake cycle should start from the resident prepared session image")
        XCTAssertTrue(source.contains("since: snapshot.interval.start"),
                      "The current wake cycle should use the bounded recent reader")
        XCTAssertTrue(source.contains("maximumPoints: 100_000"),
                      "Completed historical days must keep the exact-window reader")
        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("finishCancelledHeartRateRequest"))

        let refreshStart = try XCTUnwrap(source.range(
            of: "private func refreshTimelineHeartRate(window:"
        ))
        let refreshEnd = try XCTUnwrap(source.range(
            of: "private func finishCancelledHeartRateRequest",
            range: refreshStart.upperBound..<source.endIndex
        ))
        let refresh = String(source[refreshStart.lowerBound..<refreshEnd.lowerBound])
        let initialLive = try XCTUnwrap(refresh.range(
            of: "appendFreshLiveHeartRate(stressMonitorStore.liveHeartRate)"
        ))
        let archiveAwait = try XCTUnwrap(refresh.range(of: "await withTaskCancellationHandler"))
        XCTAssertLessThan(initialLive.lowerBound, archiveAwait.lowerBound,
                          "A current live reading must render before archive preparation completes")
    }

    func testActivityHeartRateRefreshLifecyclePreservesOneWindowAndTerminalizes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let current = AtriaActivityHeartRateWindowIdentity(
            start: start,
            historicalEnd: nil,
            isCurrent: true
        )
        let sameCurrent = AtriaActivityHeartRateWindowIdentity(
            start: start,
            historicalEnd: nil,
            isCurrent: true
        )
        let priorDay = AtriaActivityHeartRateWindowIdentity(
            start: start.addingTimeInterval(-86_400),
            historicalEnd: start,
            isCurrent: false
        )

        XCTAssertTrue(AtriaActivityHeartRateRefreshPolicy.preservesProjection(
            previous: current,
            next: sameCurrent
        ))
        XCTAssertFalse(AtriaActivityHeartRateRefreshPolicy.preservesProjection(
            previous: current,
            next: priorDay
        ))
        XCTAssertEqual(AtriaActivityHeartRateRefreshPolicy.terminalState(readSucceeded: true),
                       .loaded)
        XCTAssertEqual(AtriaActivityHeartRateRefreshPolicy.terminalState(readSucceeded: false),
                       .unavailable)
        XCTAssertEqual(AtriaActivityHeartRateRefreshPolicy.cancellationState(hasVisiblePoints: true),
                       .loaded)
        XCTAssertEqual(AtriaActivityHeartRateRefreshPolicy.cancellationState(hasVisiblePoints: false),
                       .interrupted)
    }

    func testHighFrequencyStressObservationIsConfinedToActivityLeaves() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let tabStart = try XCTUnwrap(source.range(of: "struct AtriaActivityMonitorTab: View"))
        let timelineHostStart = try XCTUnwrap(source.range(
            of: "private struct AtriaActivityTimelineHost: View",
            range: tabStart.upperBound..<source.endIndex
        ))
        let rootBeforeTimelineLeaf = String(source[tabStart.lowerBound..<timelineHostStart.lowerBound])

        XCTAssertTrue(rootBeforeTimelineLeaf.contains(
            "let stressMonitorStore: AtriaStressMonitorStore"
        ))
        XCTAssertTrue(rootBeforeTimelineLeaf.contains("@Environment(\\.scenePhase)"),
                      "Foregrounding must still recompute the bounded day-section request")
        XCTAssertFalse(rootBeforeTimelineLeaf.contains(
            "@ObservedObject var stressMonitorStore: AtriaStressMonitorStore"
        ), "A live stress publication must not invalidate the whole Activity log")
        XCTAssertFalse(rootBeforeTimelineLeaf.contains(".task(id: timelineSignalWindowKey)"))
        XCTAssertFalse(rootBeforeTimelineLeaf.contains("@State private var liveHeartRateTail"))

        let timelineHostEnd = try XCTUnwrap(source.range(
            of: "private var addActivityMenu: some View",
            range: timelineHostStart.upperBound..<source.endIndex
        ))
        let timelineHost = String(source[timelineHostStart.lowerBound..<timelineHostEnd.lowerBound])
        XCTAssertTrue(timelineHost.contains(
            "@ObservedObject var stressMonitorStore: AtriaStressMonitorStore"
        ))
        XCTAssertTrue(timelineHost.contains("@State private var liveHeartRateTail"))
        XCTAssertTrue(timelineHost.contains(".task(id: timelineSignalWindowKey)"))
        XCTAssertTrue(timelineHost.contains(".task(id: timelineStressRequestKey)"))
        XCTAssertTrue(timelineHost.contains("AtriaActivityTimelineRefreshPolicy.shouldRefresh"))
        XCTAssertTrue(timelineHost.contains(
            "SessionStore.recoveredDataRecomputeDidPublishNotification"
        ))
        XCTAssertTrue(timelineHost.contains("private var timelineSignalInspector"))

        let sheetHostStart = try XCTUnwrap(source.range(
            of: "private struct AtriaActivityWorkoutDetailSheetHost: View"
        ))
        let sheetStart = try XCTUnwrap(source.range(
            of: "private struct AtriaActivityWorkoutDetailSheet: View",
            range: sheetHostStart.upperBound..<source.endIndex
        ))
        let sheetHost = String(source[sheetHostStart.lowerBound..<sheetStart.lowerBound])
        XCTAssertTrue(sheetHost.contains(
            "let stressMonitorStore: AtriaStressMonitorStore"
        ))
        XCTAssertFalse(sheetHost.contains(
            "@ObservedObject var stressMonitorStore: AtriaStressMonitorStore"
        ), "Unrelated pulse/state publications must not refilter restored workout history")
        XCTAssertTrue(sheetHost.contains(
            ".onReceive(stressMonitorStore.$historyRevision.removeDuplicates())"
        ))
        XCTAssertTrue(sheetHost.contains(
            ".onReceive(stressMonitorStore.$historyLoadState.removeDuplicates())"
        ))
        XCTAssertTrue(timelineHost.contains(
            "AtriaActivityTimelineStressSourceSnapshot"
        ))
        XCTAssertTrue(timelineHost.contains(
            "Task.detached(priority: .utility)"
        ))
        XCTAssertTrue(timelineHost.contains(
            "if stressProjectionWindowKey != requestKey.window"
        ), "Same-window live revisions should preserve the visible projection")
    }

    @MainActor
    func testWorkoutStressProjectionPreservesInclusiveMeasuredWindow() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(600)
        let history: [AtriaStressMonitorStore.StressHistoryPoint] = [
            .init(t: start.addingTimeInterval(-1), activation: 0.1, level: .calm, hrvAvailable: true),
            .init(t: start, activation: 0.2, level: .low, hrvAvailable: true),
            .init(t: end, activation: 0.4, level: .medium, hrvAvailable: true),
            .init(t: end.addingTimeInterval(1), activation: 0.8, level: .high, hrvAvailable: true),
        ]

        let readings = AtriaActivityWorkoutStressProjection.readings(
            history: history,
            start: start,
            end: end
        )

        XCTAssertEqual(readings.map(\.date), [start, end])
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings[0].score, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(readings[1].score, 1.2, accuracy: 0.000_001)
    }

    @MainActor
    func testWorkoutHROnlyEvidenceRemainsNumericAtExplicitLowerConfidence() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func hrOnlyFact(date: Date,
                        score: Double,
                        hrStress: Double) -> AtriaPhysiologicalStressModel.MinuteFact {
            AtriaPhysiologicalStressModel.MinuteFact(
                date: date,
                score: score,
                unsmoothedScore: score,
                meanHeartRate: 82,
                rmssd: nil,
                hrStress: hrStress,
                hrvStress: nil,
                heartRateWeight: 1,
                motionContext: .unavailable,
                sleepContext: .awake,
                confidence: .low,
                baselineLearning: false
            )
        }
        let history: [AtriaStressMonitorStore.StressHistoryPoint] = [
            .init(t: start,
                  activation: 0.1,
                  level: .calm,
                  hrvAvailable: false,
                  minuteFact: hrOnlyFact(date: start,
                                         score: 0.3,
                                         hrStress: 0.1)),
            .init(t: start.addingTimeInterval(30),
                  activation: AtriaStressMonitor.mediumUpperBound,
                  level: .medium,
                  hrvAvailable: false,
                  minuteFact: hrOnlyFact(
                    date: start.addingTimeInterval(30),
                    score: 2,
                    hrStress: AtriaStressMonitor.mediumUpperBound
                  )),
        ]

        let projection = AtriaActivityWorkoutStressProjection.evidence(
            history: history,
            start: start,
            end: start.addingTimeInterval(60)
        )
        let summary = AtriaWorkoutStressTraceSummary(
            readings: projection.displayedReadings
        )

        XCTAssertEqual(projection.presentation, .physiologicalStress)
        XCTAssertEqual(projection.stressPoints.count, 2)
        XCTAssertEqual(projection.stressPoints[0].reading.score, 0.3, accuracy: 1e-12)
        XCTAssertEqual(projection.stressPoints[1].reading.score, 2, accuracy: 1e-12)
        XCTAssertEqual(projection.stressPoints.map(\.reading.confidence), [.low, .low])
        XCTAssertTrue(projection.cardiacArousalPoints.isEmpty,
                      "Version-3 HR-only facts stay on the physiological-stress line")
        XCTAssertEqual(summary.readingCount, 2)
        XCTAssertEqual(try XCTUnwrap(summary.low), 0.3, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.high), 2, accuracy: 1e-12)
    }

    @MainActor
    func testWorkoutMixedProvenanceSharesNumericScaleButRealTimeGapRemainsBlank() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let gapStart = start.addingTimeInterval(
            30 + AtriaPhysiologicalStressModel.maximumFactContinuityGap + 1
        )
        let readings = [
            AtriaStressDetailReading(date: start,
                                     score: 2.1,
                                     evidenceMode: .cardiacArousal,
                                     level: .medium),
            AtriaStressDetailReading(date: start.addingTimeInterval(30),
                                     score: 0.9,
                                     evidenceMode: .physiologicalStress,
                                     level: .low),
            AtriaStressDetailReading(date: gapStart,
                                     score: 1.8,
                                     evidenceMode: .cardiacArousal,
                                     level: .medium),
            AtriaStressDetailReading(date: gapStart.addingTimeInterval(30),
                                     score: 1.5,
                                     evidenceMode: .physiologicalStress,
                                     level: .medium),
        ]

        let projection = AtriaActivityWorkoutStressProjection.evidence(readings: readings)
        let summary = AtriaWorkoutStressTraceSummary(readings: readings)

        XCTAssertEqual(projection.presentation, .physiologicalStress)
        XCTAssertEqual(summary.readingCount, 4)
        XCTAssertEqual(try XCTUnwrap(summary.low), 0.9, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.high), 2.1, accuracy: 1e-12)
        XCTAssertEqual(summary.points.map(\.segment), [0, 0, 1, 1],
                       "Only the genuine time hole should split the numeric trace")
    }

    func testActivityStressEmptyStateDistinguishesRestoreFailureRetentionAndNoReadings() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = DateInterval(start: now.addingTimeInterval(-12 * 3_600),
                                  end: now.addingTimeInterval(-11 * 3_600))
        let expired = DateInterval(start: now.addingTimeInterval(-72 * 3_600),
                                   end: now.addingTimeInterval(-71 * 3_600))

        XCTAssertEqual(AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: .loading,
            interval: recent,
            isCurrentPhysiologicalDay: false,
            currentState: .noSignal,
            now: now
        ), "Loading saved stress readings…")
        XCTAssertTrue(AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: .unavailable,
            interval: recent,
            isCurrentPhysiologicalDay: false,
            currentState: .noSignal,
            now: now
        ).contains("couldn’t be read"))
        XCTAssertTrue(AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: .loaded,
            interval: expired,
            isCurrentPhysiologicalDay: false,
            currentState: .noSignal,
            now: now
        ).contains("past two days"))
        XCTAssertEqual(AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: .loaded,
            interval: recent,
            isCurrentPhysiologicalDay: false,
            currentState: .noSignal,
            now: now
        ), "No measured stress readings were recorded in the selected day range.")
        XCTAssertEqual(AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: .loaded,
            interval: recent,
            isCurrentPhysiologicalDay: true,
            currentState: AtriaStressState(level: .low,
                                           label: "Low",
                                           detail: "Personal HR + HRV",
                                           kind: .scored,
                                           confidence: 1,
                                           rawActivation: 0.4,
                                           hrvAvailable: true),
            now: now
        ), "No measured stress reading has been recorded since waking.")
    }

    func testOvernightHeartRateArchiveReadDistinguishesFailureWearAndBaseline() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(8 * 3_600)

        let unreadable = AtriaSleepStressArchiveProjection.make(
            read: nil,
            sleepStart: start,
            sleepEnd: end,
            restingHeartRate: 55
        )
        XCTAssertEqual(unreadable.availability, .unavailable)

        let emptyRead = HistoricalArchive.HeartRateWindowRead(
            points: [],
            scannedFileCount: 1,
            scannedByteCount: 128
        )
        let insufficientWear = AtriaSleepStressArchiveProjection.make(
            read: emptyRead,
            sleepStart: start,
            sleepEnd: end,
            restingHeartRate: 55
        )
        XCTAssertEqual(insufficientWear.availability, .insufficientWear)

        let shortReadableWindow = AtriaSleepStressArchiveProjection.make(
            read: emptyRead,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(45 * 60),
            restingHeartRate: 55
        )
        XCTAssertEqual(shortReadableWindow.availability, .insufficientWear,
                       "A successful short-window read is insufficient wear, not unavailable history")

        let missingBaseline = AtriaSleepStressArchiveProjection.make(
            read: nil,
            sleepStart: start,
            sleepEnd: end,
            restingHeartRate: nil
        )
        XCTAssertEqual(missingBaseline.availability, .baselineNeeded)

        let coveredPoints = (0..<12).map { index in
            HistoricalArchive.HeartRatePoint(
                t: start.addingTimeInterval(Double(index * 20 * 60)),
                bpm: 62
            )
        }
        let coveredRead = HistoricalArchive.HeartRateWindowRead(
            points: coveredPoints,
            scannedFileCount: 1,
            scannedByteCount: 1_024
        )
        let ready = AtriaSleepStressArchiveProjection.make(
            read: coveredRead,
            sleepStart: start,
            sleepEnd: end,
            restingHeartRate: 55
        )
        XCTAssertEqual(ready.availability, .ready)
    }

    func testExactWindowHeartRateUnionDedupesAndClipsToWindow() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = DateInterval(start: base, end: base.addingTimeInterval(600))
        let canonical = [HistoricalArchive.HeartRatePoint(t: base, bpm: 60)]
        let archive = [
            HistoricalArchive.HeartRatePoint(t: base, bpm: 60), // exact duplicate of canonical
            HistoricalArchive.HeartRatePoint(t: base.addingTimeInterval(60), bpm: 62),
        ]
        let observed = [
            HistoricalArchive.HeartRatePoint(t: base.addingTimeInterval(120), bpm: 64),
            HistoricalArchive.HeartRatePoint(t: base.addingTimeInterval(-30), bpm: 99), // before window
            HistoricalArchive.HeartRatePoint(t: base.addingTimeInterval(700), bpm: 99), // after window
        ]
        let union = AtriaExactWindowHeartRate.union(canonical: canonical,
                                                    archive: archive,
                                                    observed: observed,
                                                    interval: interval)
        // Deduplicated, clipped to the window, time-sorted; nothing synthesized.
        XCTAssertEqual(union.map(\.bpm), [60, 62, 64])
        XCTAssertEqual(union.map(\.t), [base,
                                        base.addingTimeInterval(60),
                                        base.addingTimeInterval(120)])
    }

    func testActivityHeartRateSurfacesObservedHistoryWhenArchiveEmpty() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let interval = DateInterval(start: base, end: base.addingTimeInterval(600))
        // Six observed minute facts, empty archive/canonical — the stable-BPM
        // case where the change-triggered live tail alone would show one point.
        let observed = (0..<6).map {
            HistoricalArchive.HeartRatePoint(t: base.addingTimeInterval(Double($0) * 60), bpm: 70 + $0)
        }
        let union = AtriaExactWindowHeartRate.union(canonical: [],
                                                    archive: [],
                                                    observed: observed,
                                                    interval: interval)
        let projection = AtriaActivityTimelineSignalProjection.heartRate(samples: union, interval: interval)
        XCTAssertGreaterThan(projection.points.count, 1)
        XCTAssertEqual(projection.measuredSampleCount, 6)
    }

    func testOvernightProjectionUsesObservedWhenArchiveReadIsNil() {
        let sleepStart = Date(timeIntervalSince1970: 1_800_000_000)
        let sleepEnd = sleepStart.addingTimeInterval(8 * 3600)
        let observed = (0..<20).map {
            HistoricalArchive.HeartRatePoint(t: sleepStart.addingTimeInterval(Double($0) * 20 * 60), bpm: 58)
        }
        // A nil archive read still builds from observed history rather than
        // collapsing to unavailable.
        let withObserved = AtriaSleepStressArchiveProjection.make(read: nil,
                                                                  sleepStart: sleepStart,
                                                                  sleepEnd: sleepEnd,
                                                                  restingHeartRate: 55,
                                                                  canonical: [],
                                                                  observed: observed)
        XCTAssertNotEqual(withObserved.availability, .unavailable)
        // A nil read with no source at all remains a truthful unavailable state.
        let empty = AtriaSleepStressArchiveProjection.make(read: nil,
                                                           sleepStart: sleepStart,
                                                           sleepEnd: sleepEnd,
                                                           restingHeartRate: 55)
        XCTAssertEqual(empty.availability, .unavailable)
    }

    func testOvernightLoadingAvailabilityIsDistinctFromUnavailable() {
        XCTAssertNotEqual(AtriaSleepStressProjection.Availability.loading, .unavailable)
        XCTAssertNotEqual(AtriaSleepStressProjection.Availability.loading.title,
                          AtriaSleepStressProjection.Availability.unavailable.title)
    }

    func testHealthAndActivityOvernightLoadUseOneTypedArchiveBoundary() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let health = try String(
            contentsOf: sourceDirectory.appendingPathComponent("AtriaHealthScreen.swift"),
            encoding: .utf8
        )
        let activity = try String(
            contentsOf: sourceDirectory.appendingPathComponent("AtriaActivityMonitor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(health.contains("AtriaSleepStressArchiveProjection.load("))
        XCTAssertTrue(activity.contains("AtriaSleepStressArchiveProjection.load("))
        XCTAssertFalse(health.contains(
            "maximumPoints: 50_000)?.points ?? []"
        ), "An unreadable exact window must not be collapsed into insufficient wear")
        XCTAssertFalse(activity.contains(
            "maximumPoints: 50_000)?.points ?? []"
        ), "Health and Activity must preserve the same typed overnight read failure")
    }

    func testWorkoutStressEmptyStateUsesTheSameLoadAndRetentionAuthority() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AtriaActivityStressHistoryPresentation.workoutEmptyMessage(
            loadState: .loading,
            workoutEnd: now,
            now: now
        ), "Loading saved stress readings…")
        XCTAssertTrue(AtriaActivityStressHistoryPresentation.workoutEmptyMessage(
            loadState: .unavailable,
            workoutEnd: now,
            now: now
        ).contains("couldn’t be read"))
        XCTAssertTrue(AtriaActivityStressHistoryPresentation.workoutEmptyMessage(
            loadState: .loaded,
            workoutEnd: now.addingTimeInterval(-72 * 3_600),
            now: now
        ).contains("outside that window"))
        XCTAssertEqual(AtriaActivityStressHistoryPresentation.workoutEmptyMessage(
            loadState: .loaded,
            workoutEnd: now,
            now: now
        ), "No measured stress readings were recorded during this workout.")
    }

    func testDetectedActivityPresentationUsesOnlyExplicitClassifierHint() {
        let generic = AtriaDetectedActivityPresentation.make(kind: .activityCandidate,
                                                             suggestedActivityType: nil)
        XCTAssertEqual(generic.title, "Activity detected")
        XCTAssertEqual(generic.icon, "waveform.path.ecg")

        let walking = AtriaDetectedActivityPresentation.make(kind: .activityCandidate,
                                                             suggestedActivityType: .walking)
        XCTAssertEqual(walking.title, "Walking suggested")
        XCTAssertEqual(walking.icon, AtriaWorkoutActivityType.walking.icon)

        let genericWorkout = AtriaDetectedActivityPresentation.make(kind: .workout,
                                                                    suggestedActivityType: nil)
        XCTAssertEqual(genericWorkout.title, "Workout detected")
        XCTAssertEqual(genericWorkout.icon, "figure.mixed.cardio")

        let now = Date()
        let classified = ActivityDetection(id: UUID(),
                                           kind: .activityCandidate,
                                           confidence: .medium,
                                           start: now.addingTimeInterval(-600),
                                           end: now,
                                           duration: 600,
                                           avgHR: 118,
                                           peakHR: 136,
                                           reason: "independent classifier evidence",
                                           suggestedActivityType: .cycling)
        XCTAssertEqual(classified.suggestedActivityType, .cycling)
        XCTAssertEqual(AtriaDetectedActivityPresentation.make(
            kind: classified.kind,
            suggestedActivityType: classified.suggestedActivityType
        ), AtriaDetectedActivityPresentation(title: "Cycling suggested", icon: "bicycle"))
    }

    private func workout(samples: Int = 177,
                         avgHR: Int = 86,
                         peakHR: Int = 100,
                         strain: Double? = 0.051,
                         coverage: Int = 100,
                         reason: String = "test",
                         start: Date = Date(timeIntervalSince1970: 1_800_000_000),
                         duration: TimeInterval = 173) -> UserConfirmedWorkout {
        return UserConfirmedWorkout(id: "workout",
                                    createdAt: start,
                                    start: start,
                                    end: start.addingTimeInterval(duration),
                                    label: "Workout",
                                    source: "test",
                                    confidence: "high",
                                    sessions: 1,
                                    samples: samples,
                                    avgHR: avgHR,
                                    peakHR: peakHR,
                                    p95HR: 96,
                                    p99HR: 99,
                                    thresholdHR: 124,
                                    streamCoveragePercent: coverage,
                                    observedDuration: duration,
                                    reason: reason,
                                    strain: strain,
                                    zoneSeconds: [:])
    }

    func testGentleWorkoutWithHeartRateDoesNotClaimNoHRData() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout()), "Strain 0.1")
    }

    func testOnlyMissingSamplesClaimNoHRData() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(samples: 0)), "No HR data")
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(avgHR: 0)), "No HR data")
    }

    func testSparseHeartRateRemainsVisibleButCannotClaimPreciseStrain() {
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: workout(strain: 1.1, coverage: 40)),
                       "40% HR · Incomplete")
    }

    func testSeverelySparseWorkoutDoesNotShowPreciseDerivedMetrics() {
        let sparse = workout(samples: 58, avgHR: 118, strain: 0.17, coverage: 3)

        XCTAssertTrue(AtriaWorkoutMetricPresentation.metricsAreIncomplete(sparse))
        XCTAssertEqual(AtriaActivityMonitorTab.strainBadge(for: sparse), "3% HR · Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.strainText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.averageHeartRateText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.energyText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(sparse),
                       "3% HR · Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(sparse), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(sparse),
                       .init(strain: "Incomplete",
                             peakHeartRate: "--",
                             averageHeartRate: nil,
                             includesZoneMinutes: false))

        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(complete),
                       "126 avg · 100 peak")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(complete), "100")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.shareMetrics(complete),
                       .init(strain: "5.4",
                             peakHeartRate: "100",
                             averageHeartRate: "126",
                             includesZoneMinutes: true))
    }

    func testWorkoutNumericMetricsRequireSeventyFivePercentCoverage() {
        for coverage in [24, 25, 40, 74] {
            let partial = workout(samples: 1_200,
                                  avgHR: 126,
                                  peakHR: 154,
                                  strain: 5.4,
                                  coverage: coverage)
            XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(partial), .incomplete)
            XCTAssertTrue(AtriaWorkoutMetricPresentation.metricsAreIncomplete(partial))
            XCTAssertEqual(AtriaWorkoutMetricPresentation.strainText(partial), "Incomplete")
            XCTAssertFalse(AtriaWorkoutMetricPresentation.shareMetrics(partial).includesZoneMinutes)
        }

        let qualified = workout(samples: 1_200,
                                avgHR: 126,
                                peakHR: 154,
                                strain: 5.4,
                                coverage: 75)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(qualified), .complete)
        XCTAssertFalse(AtriaWorkoutMetricPresentation.metricsAreIncomplete(qualified))
        XCTAssertEqual(AtriaWorkoutMetricPresentation.strainText(qualified), "5.4")
        XCTAssertTrue(AtriaWorkoutMetricPresentation.shareMetrics(qualified).includesZoneMinutes)
    }

    func testMaterialContinuousGapRemainsPartialAboveCoverageThreshold() {
        let gymWorkout = workout(samples: 2_563,
                                 avgHR: 120,
                                 peakHR: 158,
                                 strain: 4.246,
                                 coverage: 78,
                                 reason: "stream_gaps")

        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(gymWorkout),
                       .incomplete)
        XCTAssertTrue(AtriaWorkoutMetricPresentation.metricsAreIncomplete(gymWorkout))
        XCTAssertEqual(AtriaWorkoutMetricPresentation.strainText(gymWorkout), "≥ 4.2")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.averageHeartRateText(gymWorkout),
                       "120 observed")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(gymWorkout),
                       "158 observed")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.compactStatus(gymWorkout),
                       "78% HR · Partial")
        XCTAssertFalse(AtriaWorkoutMetricPresentation.shareMetrics(gymWorkout)
            .includesZoneMinutes)
    }

    func testUnavailableAndOneSampleHeartRateNeverExposeNumericPeak() {
        let unavailable = workout(samples: 0, avgHR: 0, peakHR: 0)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(unavailable), .unavailable)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(unavailable), "No HR data")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(unavailable), "No HR data")

        let oneSample = workout(samples: 1, avgHR: 126, peakHR: 150, coverage: 100)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(oneSample), .incomplete)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.averageHeartRateText(oneSample), "Incomplete")
        XCTAssertEqual(AtriaWorkoutMetricPresentation.peakHeartRateText(oneSample), "Incomplete")

        let corruptPeak = workout(samples: 200, avgHR: 126, peakHR: 0, coverage: 92)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateState(corruptPeak), .incomplete)
        XCTAssertEqual(AtriaWorkoutMetricPresentation.heartRateSummaryText(corruptPeak),
                       "92% HR · Incomplete")
    }

    func testDayStrainIsIncompleteWhenAnySameDayWorkoutIsSeverelySparse() {
        let sparse = workout(samples: 58, avgHR: 118, strain: 0.17, coverage: 3)
        let complete = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)

        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                           strain: 0.17,
                                                                           workouts: [sparse]))
        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                           strain: 5.4,
                                                                           workouts: [sparse]))
        XCTAssertTrue(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: sparse.start,
                                                                           strain: 0.17,
                                                                           workouts: [sparse, complete]),
                      "a dense workout cannot prove the load missing from a sparse workout")
        XCTAssertFalse(AtriaWorkoutMetricPresentation.dayStrainIsIncomplete(day: complete.start,
                                                                            strain: 5.4,
                                                                            workouts: [complete]))
    }

    func testCurrentCycleStrainKeepsPriorCivilDaySparseQualifierAfterMidnight() {
        let cycleStart = Date(timeIntervalSince1970: 1_800_000_000)
        let midnight = cycleStart.addingTimeInterval(12 * 60 * 60)
        let now = midnight.addingTimeInterval(60 * 60)
        let sparseBeforeMidnight = workout(
            samples: 2_563,
            avgHR: 120,
            peakHR: 158,
            strain: 4.246,
            coverage: 78,
            reason: "stream_gaps",
            start: midnight.addingTimeInterval(-45 * 60),
            duration: 35 * 60
        )

        XCTAssertTrue(AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(
            start: cycleStart,
            end: now,
            strain: 14.0,
            workouts: [sparseBeforeMidnight]
        ))
        XCTAssertFalse(AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(
            start: midnight,
            end: now,
            strain: 1.0,
            workouts: [sparseBeforeMidnight]
        ))
    }

    func testActivityReviewProjectionShowsUnsavedDetectorWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let detection = ActivityDetection(id: UUID(),
                                          kind: .activityCandidate,
                                          confidence: .medium,
                                          start: day.addingTimeInterval(600),
                                          end: day.addingTimeInterval(2_400),
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 154,
                                          reason: "test")

        let visible = AtriaActivityReviewProjection.visibleDetections(
            [detection],
            workoutReview: nil,
            confirmedWorkouts: [],
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(visible, [detection])
    }

    func testActivityReviewProjectionDeduplicatesConfirmedAndHigherQualityReviewWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let start = day.addingTimeInterval(600)
        let end = start.addingTimeInterval(1_800)
        let detection = ActivityDetection(id: UUID(),
                                          kind: .workout,
                                          confidence: .medium,
                                          start: start,
                                          end: end,
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 154,
                                          reason: "test")
        let review = WorkoutReviewCandidate(id: "review",
                                            start: start,
                                            end: end,
                                            kind: .activityCandidate,
                                            confidence: .medium,
                                            duration: 1_800,
                                            avgHR: 118,
                                            peakHR: 154,
                                            streamCoveragePercent: 92,
                                            observedDuration: 1_700,
                                            droppedGapSeconds: 100,
                                            maxSampleGap: 12,
                                            gapCount: 2,
                                            reason: "test")

        XCTAssertTrue(AtriaActivityReviewProjection.visibleDetections(
            [detection],
            workoutReview: review,
            confirmedWorkouts: [],
            selectedDay: day,
            calendar: calendar
        ).isEmpty, "the cached review window is the single review row")

        let confirmed = workout(samples: 1_200, avgHR: 126, strain: 5.4, coverage: 92)
        let matchingReview = WorkoutReviewCandidate(id: "confirmed-review",
                                                    start: confirmed.start,
                                                    end: confirmed.end,
                                                    kind: .activityCandidate,
                                                    confidence: .medium,
                                                    duration: confirmed.duration,
                                                    avgHR: confirmed.avgHR,
                                                    peakHR: confirmed.peakHR,
                                                    streamCoveragePercent: 92,
                                                    observedDuration: confirmed.duration,
                                                    droppedGapSeconds: 0,
                                                    maxSampleGap: 1,
                                                    gapCount: 0,
                                                    reason: "test")
        XCTAssertNil(AtriaActivityReviewProjection.visibleWorkoutReview(
            matchingReview,
            confirmedWorkouts: [confirmed],
            selectedDay: confirmed.start,
            calendar: calendar
        ))
    }

    func testDismissedWorkoutWindowLeavesSleepAndPhysiologicalHistoryIntact() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let dismissed = ActivityDetection(id: UUID(),
                                          kind: .activityCandidate,
                                          confidence: .medium,
                                          start: start,
                                          end: start.addingTimeInterval(1_800),
                                          duration: 1_800,
                                          avgHR: 118,
                                          peakHR: 150,
                                          reason: "test")
        let otherActivity = ActivityDetection(id: UUID(),
                                              kind: .workout,
                                              confidence: .medium,
                                              start: start.addingTimeInterval(7_200),
                                              end: start.addingTimeInterval(9_000),
                                              duration: 1_800,
                                              avgHR: 125,
                                              peakHR: 160,
                                              reason: "test")
        let sleep = ActivityDetection(id: UUID(),
                                      kind: .sleepCandidate,
                                      confidence: .medium,
                                      start: start,
                                      end: start.addingTimeInterval(28_800),
                                      duration: 28_800,
                                      avgHR: 55,
                                      peakHR: 72,
                                      reason: "test")
        let tombstone = AtriaDismissedWorkoutCandidate(start: start.addingTimeInterval(60),
                                                       end: start.addingTimeInterval(1_740))

        let visible = SessionStore.activityDetectionsForUI(
            [dismissed, otherActivity, sleep],
            dismissedCandidates: [tombstone]
        )

        XCTAssertEqual(Set(visible.map(\.id)), [otherActivity.id, sleep.id])
        XCTAssertTrue(visible.contains(sleep),
                      "Workout dismissal must not erase sleep evidence from physiological history")
    }

    func testSelectedDayTimelineIncludesEveryConfirmedActivityTypeWithValidMappedIcon() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let workouts = AtriaWorkoutActivityType.allCases.enumerated().map { offset, type in
            timelineWorkout(id: type.id,
                            start: day.addingTimeInterval(Double(offset * 120)),
                            end: day.addingTimeInterval(Double(offset * 120 + 60)),
                            type: type)
        }

        let spans = AtriaActivityTimelineBuilder.workoutSpans(workouts: workouts,
                                                               selectedDay: day,
                                                               calendar: calendar)

        XCTAssertEqual(spans.count, AtriaWorkoutActivityType.allCases.count)
        XCTAssertEqual(Set(spans.map(\.id)).count, spans.count)
        XCTAssertEqual(Set(spans.map(\.lane)).count, 1,
                       "Non-overlapping activities should share one compact lane")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: spans.map { ($0.label, $0.icon) }),
                       Dictionary(uniqueKeysWithValues: AtriaWorkoutActivityType.allCases.map {
                           ($0.rawValue, $0.icon)
                       }))
        for type in AtriaWorkoutActivityType.allCases {
            XCTAssertNotNil(UIImage(systemName: type.icon),
                            "\(type.rawValue) must use an available native SF Symbol")
        }
    }

    func testActivityIconsPreferSpecificSubtypeAndLegacyUserLabel() {
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Sport",
                                                     subtype: "Basketball",
                                                     label: "Sport"),
                       AtriaWorkoutActivityType.basketball.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Cardio",
                                                     subtype: "Stair climber",
                                                     label: "Cardio"),
                       AtriaWorkoutActivityType.stairClimber.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "HIIT",
                                                     subtype: "Jump rope",
                                                     label: "Intervals"),
                       AtriaWorkoutActivityType.jumpRope.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Other",
                                                     subtype: nil,
                                                     label: "Evening dance"),
                       AtriaWorkoutActivityType.dance.icon)
        XCTAssertEqual(AtriaActivityDisplayIcon.icon(activityType: "Strength",
                                                     subtype: "Push",
                                                     label: "Chest"),
                       AtriaWorkoutActivityType.strength.icon)
    }

    func testSleepTimelineAndRowsShareCanonicalCrossDayDeduplication() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                        month: 7,
                                                                        day: 12)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let savedStart = firstDay.addingTimeInterval(23 * 3_600)
        let savedEnd = secondDay.addingTimeInterval(7 * 3_600)
        let saved = activitySleep(id: "saved",
                                  day: secondDay,
                                  start: savedStart,
                                  end: savedEnd,
                                  confirmed: true)
        let duplicatePending = activitySleep(id: "pending-duplicate",
                                             day: secondDay,
                                             start: savedStart.addingTimeInterval(5 * 60),
                                             end: savedEnd.addingTimeInterval(-5 * 60),
                                             confirmed: false)
        let snapshot = SleepHistorySnapshot(nights: [saved],
                                            confirmedCount: 1,
                                            candidateCount: 0)

        let canonical = AtriaActivitySelectedDaySleeps.canonical(
            snapshot: snapshot,
            pendingReview: duplicatePending
        )
        let firstDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: duplicatePending,
            selectedDay: firstDay,
            calendar: calendar
        )
        let secondDayRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: duplicatePending,
            selectedDay: secondDay,
            calendar: calendar
        )

        XCTAssertEqual(canonical.map(\.id), [saved.id],
                       "A detector replay must not draw a second icon for a saved sleep")
        XCTAssertEqual(firstDayRows.map(\.id), [saved.id])
        XCTAssertEqual(secondDayRows.map(\.id), [saved.id],
                       "A cross-midnight timeline marker must have an editable row on both days")
    }

    func testSleepProjectionKeepsDistinctPendingNapAndLegacyDayOnlyRecord() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let saved = activitySleep(id: "legacy",
                                  day: day,
                                  start: nil,
                                  end: nil,
                                  confirmed: true)
        let pendingNap = activitySleep(id: "pending-nap",
                                       day: day,
                                       start: day.addingTimeInterval(15 * 3_600),
                                       end: day.addingTimeInterval(15.5 * 3_600),
                                       confirmed: false)
        let snapshot = SleepHistorySnapshot(nights: [saved],
                                            confirmedCount: 1,
                                            candidateCount: 0)

        let visible = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: pendingNap,
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(Set(visible.map(\.id)), [saved.id, pendingNap.id])
    }

    func testNapReviewCandidateSurvivesAlongsideConfirmedMainSleep() throws {
        // The exact 2026-08-01 gap: a real daytime nap must keep its own
        // reviewable row even when the same day already has a confirmed main
        // sleep (which owns the single main-sleep review card).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 8,
                                                                   day: 1)))
        let mainStart = day.addingTimeInterval(-1 * 3_600)
        let mainEnd = day.addingTimeInterval(6 * 3_600)
        let mainSleep = activitySleep(id: "confirmed-main",
                                      day: day,
                                      start: mainStart,
                                      end: mainEnd,
                                      confirmed: true)
        let nap = napNight(id: "nap-1405",
                           day: day,
                           start: day.addingTimeInterval(14 * 3_600 + 5 * 60),
                           end: day.addingTimeInterval(16 * 3_600 + 40 * 60))
        let snapshot = SleepHistorySnapshot(nights: [mainSleep],
                                            confirmedCount: 1,
                                            candidateCount: 0)

        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: nil,
            napReviewCandidates: [nap],
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(Set(rows.map(\.id)), [mainSleep.id, nap.id],
                       "the nap keeps its own row next to the confirmed main sleep")
        let napRow = try XCTUnwrap(rows.first { $0.id == nap.id })
        XCTAssertTrue(napRow.isNapEvidence)
        XCTAssertFalse(napRow.confirmed)
    }

    func testNapReviewCandidateDoesNotDuplicateOverlappingPendingReview() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 8,
                                                                   day: 1)))
        let start = day.addingTimeInterval(14 * 3_600)
        let end = day.addingTimeInterval(15 * 3_600)
        let pending = napNight(id: "pending-nap", day: day, start: start, end: end)
        let duplicate = napNight(id: "duplicate-nap",
                                 day: day,
                                 start: start.addingTimeInterval(3 * 60),
                                 end: end.addingTimeInterval(-3 * 60))
        let snapshot = SleepHistorySnapshot(nights: [], confirmedCount: 0, candidateCount: 0)

        let rows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot,
            pendingReview: pending,
            napReviewCandidates: [duplicate],
            selectedDay: day,
            calendar: calendar
        )

        XCTAssertEqual(rows.map(\.id), [pending.id],
                       "an overlapping nap must not be drawn twice through both surfaces")
    }

    func testCurrentDayShowsTheAnchorSleepThatEndsExactlyAtItsWakeBoundary() throws {
        // Repro of "confirm made my sleep vanish": the current physiological day
        // starts at the anchoring sleep's WAKE, so that sleep ends exactly at
        // interval.start. Once confirmed it leaves the review card; with a strict
        // `end > interval.start` it is dropped from the day and disappears.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let wake = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                    month: 8,
                                                                    day: 3,
                                                                    hour: 10,
                                                                    minute: 50)))
        let sleep = activitySleep(id: "anchor-sleep",
                                  day: calendar.startOfDay(for: wake),
                                  start: wake.addingTimeInterval(-4.8 * 3_600), // ~06:03
                                  end: wake,                                    // ends AT the boundary
                                  confirmed: true)
        let snapshot = SleepHistorySnapshot(nights: [sleep],
                                            confirmedCount: 1,
                                            candidateCount: 0)
        // Current physiological day: [wake, now].
        let interval = DateInterval(start: wake, end: wake.addingTimeInterval(3 * 3_600))

        // Strict (historical days): the boundary sleep is not part of this window.
        let strict = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot, pendingReview: nil,
            interval: interval, calendar: calendar,
            includeStartBoundarySleep: false
        )
        XCTAssertTrue(strict.isEmpty,
                      "a sleep ending exactly at the boundary is not in a historical civil-day window")

        // Current physiological day: the anchoring sleep stays visible.
        let current = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: snapshot, pendingReview: nil,
            interval: interval, calendar: calendar,
            includeStartBoundarySleep: true
        )
        XCTAssertEqual(current.map(\.id), [sleep.id],
                       "the sleep you woke from must remain in today's Activity after confirming")

        // A sleep that ends strictly BEFORE the boundary is still excluded — the
        // relaxation only admits the exact anchor, never an unrelated prior sleep.
        let earlier = activitySleep(id: "earlier",
                                    day: calendar.startOfDay(for: wake),
                                    start: wake.addingTimeInterval(-9 * 3_600),
                                    end: wake.addingTimeInterval(-3 * 3_600),
                                    confirmed: true)
        let earlierSnapshot = SleepHistorySnapshot(nights: [earlier],
                                                   confirmedCount: 1,
                                                   candidateCount: 0)
        let earlierRows = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: earlierSnapshot, pendingReview: nil,
            interval: interval, calendar: calendar,
            includeStartBoundarySleep: true
        )
        XCTAssertTrue(earlierRows.isEmpty,
                      "only a sleep touching the day start is admitted, not one ending before it")
    }

    func testNapDedupHonoursTheSeventyPercentOverlapBoundary() throws {
        // The nap-vs-confirmed-sleep dedup (substantiallyOverlaps) suppresses a
        // nap row only at >= 0.70 overlap of the shorter window. Pin that edge so
        // a refactor can't silently hide real naps (too aggressive) or double-draw
        // them (too lax). Exercised through canonical, since the gate is private.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 8,
                                                                   day: 1)))
        // Confirmed main sleep spans 100 minutes; the nap is 60 minutes (shorter).
        let sleep = activitySleep(id: "confirmed-main",
                                  day: day,
                                  start: day,
                                  end: day.addingTimeInterval(100 * 60),
                                  confirmed: true)
        let snapshot = SleepHistorySnapshot(nights: [sleep],
                                            confirmedCount: 1,
                                            candidateCount: 0)
        func napIDsWithOverlap(minutes: Double) -> Set<String> {
            // nap [100-overlap .. 160-overlap]; overlap with [0,100] = `minutes`.
            let napStart = day.addingTimeInterval((100 - minutes) * 60)
            let nap = napNight(id: "nap",
                               day: day,
                               start: napStart,
                               end: napStart.addingTimeInterval(60 * 60))
            return Set(AtriaActivitySelectedDaySleeps.canonical(
                snapshot: snapshot, pendingReview: nil, napReviewCandidates: [nap]
            ).map(\.id))
        }
        // 42/60 = 0.70 exactly → suppressed (dedup fires).
        XCTAssertEqual(napIDsWithOverlap(minutes: 42), ["confirmed-main"])
        // 41/60 ≈ 0.683 → kept as its own row.
        XCTAssertEqual(napIDsWithOverlap(minutes: 41), ["confirmed-main", "nap"])
    }

    private func napNight(id: String,
                          day: Date,
                          start: Date,
                          end: Date) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: day,
                                   start: start,
                                   end: end,
                                   duration: max(0, end.timeIntervalSince(start)),
                                   restingHR: 62,
                                   hrv: nil,
                                   respiratoryRate: nil,
                                   sleepEfficiency: 1,
                                   confidence: "review_needed",
                                   source: "nap_candidate",
                                   confirmed: false,
                                   stageSegments: [])
    }

    func testSleepStatusUsesCompactHumanCopyInsteadOfRawEnumText() {
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: false,
            confidence: "review_needed"
        ), "Review")
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: false,
            confidence: "HIGH-CONFIDENCE"
        ), "High Confidence")
        XCTAssertEqual(AtriaActivitySleepStatusPresentation.badge(
            confirmed: true,
            confidence: "review_needed"
        ), "Confirmed")
    }

    func testTimelineAxisUsesCompactSixHourLabelsAndContextualFinalTick() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let now = day.addingTimeInterval(20 * 3_600 + 17 * 60)
        let todayTicks = AtriaActivityTimelineAxis.ticks(selectedDay: day,
                                                         calendar: calendar,
                                                         now: now)
        let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: day))
        let pastTicks = AtriaActivityTimelineAxis.ticks(selectedDay: pastDay,
                                                        calendar: calendar,
                                                        now: now)

        XCTAssertEqual(todayTicks.map(\.label), ["12a", "6a", "12p", "6p", "Now"])
        XCTAssertEqual(todayTicks.map(\.date), [
            day,
            day.addingTimeInterval(6 * 3_600),
            day.addingTimeInterval(12 * 3_600),
            day.addingTimeInterval(18 * 3_600),
            now
        ])
        XCTAssertEqual(pastTicks.map(\.label), ["12a", "6a", "12p", "6p", "12a"])
        XCTAssertEqual(pastTicks.last?.accessibilityLabel, "End of day, 12 AM")
    }

    func testTimelineAxisReplacesAnchorThatWouldCollideWithNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let now = day.addingTimeInterval(17 * 3_600 + 39 * 60)

        let ticks = AtriaActivityTimelineAxis.ticks(selectedDay: day,
                                                    calendar: calendar,
                                                    now: now)

        XCTAssertEqual(ticks.map(\.label), ["12a", "6a", "12p", "Now"])
        XCTAssertFalse(ticks.contains { calendar.component(.hour, from: $0.date) == 18 })
        XCTAssertEqual(ticks.last?.date, now)
    }

    func testTimelineKeepsOverlappingActivitiesVisibleInSeparateLanesAndClipsCrossDaySpans() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                   month: 7,
                                                                   day: 12)))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let sameStart = day.addingTimeInterval(12 * 3_600)
        let workouts = [
            timelineWorkout(id: "walk", start: sameStart,
                            end: sameStart.addingTimeInterval(600), type: .walking),
            timelineWorkout(id: "run", start: sameStart,
                            end: sameStart.addingTimeInterval(600), type: .running),
            timelineWorkout(id: "cross-midnight",
                            start: day.addingTimeInterval(23.5 * 3_600),
                            end: nextDay.addingTimeInterval(1_800), type: .cycling),
            timelineWorkout(id: "tomorrow", start: nextDay.addingTimeInterval(3_600),
                            end: nextDay.addingTimeInterval(4_000), type: .rowing),
            timelineWorkout(id: "invalid", start: sameStart, end: sameStart, type: .other)
        ]

        let spans = AtriaActivityTimelineBuilder.workoutSpans(workouts: workouts,
                                                               selectedDay: day,
                                                               calendar: calendar)

        XCTAssertEqual(Set(spans.map(\.id)),
                       ["workout-walk", "workout-run", "workout-cross-midnight"])
        XCTAssertEqual(Set(spans.map(\.lane)).count, 2,
                       "Only simultaneous activities should require separate chart lanes")
        let crossing = try XCTUnwrap(spans.first { $0.id == "workout-cross-midnight" })
        XCTAssertEqual(crossing.start, day.addingTimeInterval(23.5 * 3_600))
        XCTAssertEqual(crossing.end, nextDay)
    }

    func testCurrentActivityWindowSpansMidnightFromConfirmedWakeToNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let wakeDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let wake = wakeDay.addingTimeInterval(7 * 3_600)
        let now = wakeDay.addingTimeInterval(26 * 3_600)
        let night = activitySleep(id: "main",
                                  day: wakeDay,
                                  start: wake.addingTimeInterval(-8 * 3_600),
                                  end: wake,
                                  confirmed: true)
        let snapshot = SleepHistorySnapshot(nights: [night], confirmedCount: 1, candidateCount: 0)

        let window = AtriaActivityDisplayWindow.current(now: now,
                                                        sleepHistory: snapshot,
                                                        calendar: calendar)

        XCTAssertEqual(window.interval.start, wake)
        XCTAssertEqual(window.interval.end, now)
        XCTAssertEqual(window.labelDay, wakeDay)
        XCTAssertTrue(window.isCurrentPhysiologicalDay)
    }

    func testPhysiologicalTimelineIncludesBothSidesOfMidnightAndClipsAtWake() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let interval = DateInterval(start: day.addingTimeInterval(7 * 3_600),
                                    end: day.addingTimeInterval(26 * 3_600))
        let beforeWake = timelineWorkout(id: "before-wake",
                                         start: day.addingTimeInterval(6 * 3_600),
                                         end: day.addingTimeInterval(6.5 * 3_600),
                                         type: .walking)
        let evening = timelineWorkout(id: "evening",
                                      start: day.addingTimeInterval(20 * 3_600),
                                      end: day.addingTimeInterval(21 * 3_600),
                                      type: .running)
        let afterMidnight = timelineWorkout(id: "after-midnight",
                                            start: day.addingTimeInterval(25 * 3_600),
                                            end: day.addingTimeInterval(25.5 * 3_600),
                                            type: .cycling)

        let spans = AtriaActivityTimelineBuilder.workoutSpans(
            workouts: [beforeWake, evening, afterMidnight], interval: interval
        )

        XCTAssertEqual(Set(spans.map(\.id)), ["workout-evening", "workout-after-midnight"])
    }

    func testHistoricalActivityWindowRemainsCivilDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let window = AtriaActivityDisplayWindow.historical(day: day.addingTimeInterval(15 * 3_600),
                                                           calendar: calendar)

        XCTAssertEqual(window.interval.start, day)
        XCTAssertEqual(window.interval.end, day.addingTimeInterval(24 * 3_600))
        XCTAssertFalse(window.isCurrentPhysiologicalDay)
    }

    func testActivityNextDayNavigationAdvancesUntilActualPhysiologicalTodayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let currentDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 12
        )))
        let threeDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day,
                                                       value: -3,
                                                       to: currentDay))

        let nextHistorical = AtriaActivityDayNavigation.next(
            from: threeDaysAgo,
            currentPhysiologicalDisplayDay: currentDay,
            calendar: calendar
        )
        XCTAssertEqual(nextHistorical.day,
                       try XCTUnwrap(calendar.date(byAdding: .day,
                                                  value: -2,
                                                  to: currentDay)))
        XCTAssertFalse(nextHistorical.viewsCurrentPhysiologicalDay)

        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day,
                                                    value: -1,
                                                    to: currentDay))
        let today = AtriaActivityDayNavigation.next(
            from: yesterday,
            currentPhysiologicalDisplayDay: currentDay,
            calendar: calendar
        )
        XCTAssertEqual(today.day, currentDay)
        XCTAssertTrue(today.viewsCurrentPhysiologicalDay)
    }

    func testActivityNextDayNavigationDefensivelySnapsFutureSelectionToToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let currentDay = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 12
        )))
        let future = try XCTUnwrap(calendar.date(byAdding: .day,
                                                 value: 3,
                                                 to: currentDay))

        let destination = AtriaActivityDayNavigation.next(
            from: future,
            currentPhysiologicalDisplayDay: currentDay,
            calendar: calendar
        )

        XCTAssertEqual(destination.day, currentDay)
        XCTAssertTrue(destination.viewsCurrentPhysiologicalDay)
    }

    func testTimelineLanePackingIsMinimalDeterministicAndReusesHalfOpenEnds() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let intervals = [
            AtriaActivityTimelineLaneInterval(id: "later", start: start.addingTimeInterval(20), end: start.addingTimeInterval(30)),
            AtriaActivityTimelineLaneInterval(id: "overlap", start: start.addingTimeInterval(5), end: start.addingTimeInterval(15)),
            AtriaActivityTimelineLaneInterval(id: "first", start: start, end: start.addingTimeInterval(10)),
            AtriaActivityTimelineLaneInterval(id: "touching", start: start.addingTimeInterval(10), end: start.addingTimeInterval(20))
        ]

        let assignments = AtriaActivityTimelineLanePacker.assignments(for: intervals)

        XCTAssertEqual(assignments["first"], 0)
        XCTAssertEqual(assignments["overlap"], 1)
        XCTAssertEqual(assignments["touching"], 0,
                       "An interval ending exactly at the next start must release its lane")
        XCTAssertEqual(assignments["later"], 0)
        XCTAssertEqual(Set(assignments.values), [0, 1])
    }

    func testActivityHeartRateProjectionPreservesRealExtremaAndCaptureGaps() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var samples = (0..<300).map { index in
            HistoricalArchive.HeartRatePoint(t: start.addingTimeInterval(Double(index) * 30),
                                             bpm: 80 + index % 7)
        }
        samples[74] = .init(t: samples[74].t, bpm: 42)
        samples[225] = .init(t: samples[225].t, bpm: 211)
        let secondRunStart = start.addingTimeInterval(300 * 30 + 5 * 60)
        samples.append(.init(t: secondRunStart, bpm: 91))
        samples.append(.init(t: secondRunStart.addingTimeInterval(30), bpm: 94))
        let interval = DateInterval(start: start,
                                    end: secondRunStart.addingTimeInterval(31))

        let projection = AtriaActivityTimelineSignalProjection.heartRate(
            samples: samples,
            interval: interval,
            targetPointCount: 24
        )

        XCTAssertEqual(projection.measuredSampleCount, samples.count)
        XCTAssertTrue(projection.points.contains { $0.bpm == 42 },
                      "A short real trough must survive bounded display reduction")
        XCTAssertTrue(projection.points.contains { $0.bpm == 211 },
                      "A short real peak must survive bounded display reduction")
        XCTAssertEqual(Set(projection.points.map(\.segment)), [0, 1])
        XCTAssertTrue(projection.points.allSatisfy { point in
            samples.contains { $0.t == point.t && $0.bpm == point.bpm }
        }, "Every plotted heart-rate point must be an actual archived sample")
    }

    func testActivityStressProjectionKeepsRestoredGapsAndNeverSynthesizesReadings() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let samples = [
            AtriaActivityTimelineStressSample(t: start, score: 0.4, levelRawValue: 0),
            .init(t: start.addingTimeInterval(30), score: 0.8, levelRawValue: 1),
            .init(t: start.addingTimeInterval(7 * 60), score: 2.4, levelRawValue: 2),
            .init(t: start.addingTimeInterval(7 * 60 + 30), score: 2.8, levelRawValue: 3),
            .init(t: start.addingTimeInterval(8 * 60), score: 1.2, levelRawValue: 1)
        ]
        let projection = AtriaActivityTimelineSignalProjection.stress(
            samples: samples,
            interval: DateInterval(start: start,
                                   end: start.addingTimeInterval(8 * 60))
        )

        XCTAssertEqual(projection.measuredSampleCount, 4,
                       "A sample exactly at the next civil-day boundary belongs to the next window")
        XCTAssertEqual(projection.points.map(\.segment), [0, 0, 1, 1])
        XCTAssertTrue(projection.points.allSatisfy { point in
            samples.contains { $0.t == point.t && $0.score == point.score }
        })
    }

    func testWorkoutStressChartUsesNonOvershootingLineAndRendersSingletonRuns() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaActivityMonitor.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let chartStart = try XCTUnwrap(source.range(
            of: "struct AtriaWorkoutStressTraceChart: View"
        ))
        let chartEnd = try XCTUnwrap(source.range(
            of: "/// Review-first sleep sheet",
            range: chartStart.upperBound..<source.endIndex
        ))
        let chart = String(source[chartStart.lowerBound..<chartEnd.lowerBound])

        XCTAssertTrue(chart.contains(".interpolationMethod(.linear)"))
        XCTAssertFalse(chart.contains(".interpolationMethod(.monotone)"),
                       "Spline overshoot can imply an unmeasured stress peak")
        XCTAssertTrue(chart.contains("PointMark("),
                      "An isolated measured run must remain visible as a point")
        XCTAssertTrue(chart.contains("gaps contain no recorded stress score"))
    }

    func testActivityMarkerProjectionUsesOneNonOverlappingTruthfulLane() {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let slices = AtriaActivityTimelineMarkerProjection.nonOverlappingSlices([
            .init(id: "sleep", start: start, end: start.addingTimeInterval(30), priority: 300),
            .init(id: "workout", start: start.addingTimeInterval(10),
                  end: start.addingTimeInterval(20), priority: 400),
            .init(id: "review", start: start.addingTimeInterval(12),
                  end: start.addingTimeInterval(18), priority: 100)
        ])

        XCTAssertEqual(slices.filter { $0.sourceID == "sleep" }.map { [$0.start, $0.end] }, [
            [start, start.addingTimeInterval(10)],
            [start.addingTimeInterval(20), start.addingTimeInterval(30)]
        ])
        XCTAssertEqual(slices.filter { $0.sourceID == "workout" }.count, 1)
        XCTAssertFalse(slices.contains { $0.sourceID == "review" },
                       "Fully covered lower-trust evidence must not overlap a confirmed marker")
        for pair in zip(slices, slices.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.end, pair.1.start)
        }
    }

    func testCrossMidnightWorkoutIsSelectableOnBothDaysExactlyLikeTimeline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                        month: 7,
                                                                        day: 12)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let crossing = timelineWorkout(id: "cross-midnight",
                                       start: firstDay.addingTimeInterval(23.5 * 3_600),
                                       end: secondDay.addingTimeInterval(30 * 60),
                                       type: .cycling)
        let endsAtMidnight = timelineWorkout(id: "ends-at-midnight",
                                             start: firstDay.addingTimeInterval(23 * 3_600),
                                             end: secondDay,
                                             type: .walking)
        let startsAtMidnight = timelineWorkout(id: "starts-at-midnight",
                                               start: secondDay,
                                               end: secondDay.addingTimeInterval(30 * 60),
                                               type: .running)
        let invalid = timelineWorkout(id: "invalid",
                                      start: secondDay.addingTimeInterval(60),
                                      end: secondDay.addingTimeInterval(60),
                                      type: .other)
        let workouts = [crossing, endsAtMidnight, startsAtMidnight, invalid]

        let firstDayRows = AtriaActivitySelectedDayWorkouts.overlapping(
            workouts,
            selectedDay: firstDay,
            calendar: calendar
        )
        let secondDayRows = AtriaActivitySelectedDayWorkouts.overlapping(
            workouts,
            selectedDay: secondDay,
            calendar: calendar
        )
        let secondDaySpans = AtriaActivityTimelineBuilder.workoutSpans(
            workouts: workouts,
            selectedDay: secondDay,
            calendar: calendar
        )

        XCTAssertEqual(Set(firstDayRows.map(\.id)), ["cross-midnight", "ends-at-midnight"])
        XCTAssertEqual(Set(secondDayRows.map(\.id)), ["cross-midnight", "starts-at-midnight"])
        XCTAssertEqual(Set(secondDaySpans.map(\.id)),
                       Set(secondDayRows.map { "workout-\($0.id)" }),
                       "Every workout marker must have a matching tappable row on the selected day")
    }

    private func key(sleepRevision: Int = 1,
                     workoutsRevision: Int = 1,
                     rollupsRevision: Int = 1,
                     selectedDay: Date = Date(timeIntervalSince1970: 1_800_000_000),
                     identifier: Calendar.Identifier = .gregorian,
                     timeZone: String = "UTC") -> AtriaActivitySectionsRequestKey {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return AtriaActivitySectionsRequestKey(sleepRevision: sleepRevision,
                                               workoutsRevision: workoutsRevision,
                                               rollupsRevision: rollupsRevision,
                                               selectedDay: selectedDay,
                                               calendar: calendar)
    }

    func testRequestKeyTracksRevisionsSelectedDayAndCalendarIdentityAndTimeZone() {
        let original = key()

        XCTAssertNotEqual(original, key(sleepRevision: 2))
        XCTAssertNotEqual(original, key(workoutsRevision: 2))
        XCTAssertNotEqual(original, key(rollupsRevision: 2))
        XCTAssertNotEqual(original, key(selectedDay: Date(timeIntervalSince1970: 1_800_086_400)))
        XCTAssertNotEqual(original, key(identifier: .buddhist))
        XCTAssertNotEqual(original, key(timeZone: "America/Los_Angeles"))
    }

    func testDuplicatePendingAndPublishedRequestsAreCoalesced() throws {
        var cache = AtriaActivitySectionsCache<[Int]>()
        let requestKey = key()
        let request = try XCTUnwrap(cache.request(for: requestKey))

        XCTAssertNil(cache.request(for: requestKey))
        XCTAssertTrue(cache.publish([1, 2, 3], for: request))
        XCTAssertNil(cache.request(for: requestKey))
        XCTAssertEqual(cache.value, [1, 2, 3])
    }

    func testSupersededGenerationCannotPublish() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let stale = try XCTUnwrap(cache.request(for: key()))
        let current = try XCTUnwrap(cache.request(for: key(sleepRevision: 2)))

        XCTAssertFalse(cache.publish("stale", for: stale))
        XCTAssertNil(cache.value)
        XCTAssertTrue(cache.publish("current", for: current))
        XCTAssertEqual(cache.value, "current")
    }

    func testPriorValueIsNotProjectedForANewlySelectedDayWhileItRefreshes() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let firstKey = key()
        let nextKey = key(workoutsRevision: 2)
        let first = try XCTUnwrap(cache.request(for: firstKey))
        XCTAssertTrue(cache.isLoadingWithoutValue)
        XCTAssertTrue(cache.publish("prior", for: first))

        _ = try XCTUnwrap(cache.request(for: nextKey))

        XCTAssertEqual(cache.value, "prior")
        XCTAssertEqual(cache.value(for: firstKey), "prior")
        XCTAssertNil(cache.value(for: nextKey),
                     "Rows from the prior day must not appear under the newly selected day header")
        XCTAssertFalse(cache.isLoadingWithoutValue)
    }

    func testCancelledRequestCanBeRequestedAgain() throws {
        var cache = AtriaActivitySectionsCache<String>()
        let requestKey = key()
        let cancelled = try XCTUnwrap(cache.request(for: requestKey))

        cache.cancel(cancelled)

        XCTAssertNotNil(cache.request(for: requestKey))
    }

    func testRecoveryEffectComparesNextMorningWithPrecedingPersonalBaseline() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let workoutDay = Date(timeIntervalSince1970: 1_800_000_000)
        let recoveryDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: workoutDay))
        let workout = UserConfirmedWorkout(id: "walk",
                                           createdAt: workoutDay,
                                           start: workoutDay,
                                           end: workoutDay.addingTimeInterval(1_800),
                                           label: "Walk",
                                           source: "test",
                                           confidence: "high",
                                           sessions: 1,
                                           samples: 100,
                                           avgHR: 110,
                                           peakHR: 130,
                                           p95HR: 125,
                                           p99HR: 130,
                                           thresholdHR: 100,
                                           streamCoveragePercent: 100,
                                           observedDuration: 1_800,
                                           reason: "test",
                                           zoneSeconds: [:])
        let prior = [60, 70, 80].enumerated().map { index, recovery in
            DailyRollupStoreEntry(day: calendar.date(byAdding: .day,
                                                     value: -(index + 1),
                                                     to: recoveryDay)!,
                                  recovery: recovery,
                                  calendar: calendar)
        }
        let observed = DailyRollupStoreEntry(day: recoveryDay, recovery: 80, calendar: calendar)

        let effect = AtriaActivityRecoveryEffect.make(workout: workout,
                                                      rollups: [observed] + prior,
                                                      calendar: calendar)

        XCTAssertEqual(effect.status, .observed(delta: 10, recovery: 80, baseline: 70, samples: 3))
    }

    private func timelineWorkout(id: String,
                                 start: Date,
                                 end: Date,
                                 type: AtriaWorkoutActivityType) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: id,
                             createdAt: start,
                             start: start,
                             end: end,
                             label: type.rawValue,
                             source: "test",
                             confidence: "user_confirmed",
                             sessions: 1,
                             samples: 2,
                             avgHR: 100,
                             peakHR: 120,
                             p95HR: 115,
                             p99HR: 119,
                             thresholdHR: 110,
                             streamCoveragePercent: 100,
                             observedDuration: max(0, end.timeIntervalSince(start)),
                             reason: "test",
                             activityType: type.rawValue,
                             zoneSeconds: [:])
    }


    private func activitySleep(id: String,
                               day: Date,
                               start: Date?,
                               end: Date?,
                               confirmed: Bool) -> SleepHistorySnapshot.Night {
        let duration: TimeInterval
        if let start, let end {
            duration = max(0, end.timeIntervalSince(start))
        } else {
            duration = 0
        }
        return SleepHistorySnapshot.Night(id: id,
                                          day: day,
                                          start: start,
                                          end: end,
                                          duration: duration,
                                          restingHR: 55,
                                          hrv: nil,
                                          respiratoryRate: nil,
                                          sleepEfficiency: nil,
                                          confidence: confirmed ? "confirmed" : "review_needed",
                                          source: confirmed ? "manual_sleep" : "sleep_candidate",
                                          confirmed: confirmed,
                                          stageSegments: [])
    }
}
