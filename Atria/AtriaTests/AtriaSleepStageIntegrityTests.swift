import XCTest
@testable import Atria

final class AtriaSleepStageIntegrityTests: XCTestCase {
    func testUserAdjustedEvidenceRefreshesForSampleOrCoverageGrowth() {
        XCTAssertTrue(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 1_000,
            candidateSamples: 1_001,
            existingDuration: 12_000,
            candidateCoverage: 12_000
        ))
        XCTAssertTrue(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 1_000,
            candidateSamples: 1_000,
            existingDuration: 12_000,
            candidateCoverage: 20_000
        ))
        XCTAssertFalse(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 1_000,
            candidateSamples: 1_000,
            existingDuration: 12_000,
            candidateCoverage: 12_001
        ))
        XCTAssertTrue(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 1_000,
            candidateSamples: 1_000,
            existingDuration: 12_000,
            candidateCoverage: 12_001,
            hasTimeAlignedMotionEpochs: true
        ), "motion arrival must refresh stages even when HR and coverage do not grow")
        XCTAssertTrue(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 1_000,
            candidateSamples: 1_000,
            existingDuration: 12_000,
            candidateCoverage: 12_001,
            hasStoredStageSegments: false
        ), "a stage-less record with real HR evidence must stay refresh-eligible"
            + " so pre-estimate-lane records (2026-08-12) gain their stages")
        XCTAssertFalse(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: 11,
            candidateSamples: 11,
            existingDuration: 12_000,
            candidateCoverage: 12_001,
            hasStoredStageSegments: false
        ), "the stage-less retrigger still requires minimum HR evidence")
        XCTAssertFalse(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "auto_confirmed_sleep",
            existingSamples: 1_000,
            candidateSamples: 2_000,
            existingDuration: 12_000,
            candidateCoverage: 20_000
        ))
        XCTAssertFalse(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "manual_sleep",
            existingSamples: 0,
            candidateSamples: 2_000,
            existingDuration: 0,
            candidateCoverage: 20_000
        ))
    }

    func testSensorCoverageUsesIntervalUnion() {
        let first = SavedSession(id: UUID(),
                                 start: start,
                                 end: start.addingTimeInterval(60 * 60),
                                 label: "First",
                                 points: [SavedSession.Point(t: 0, bpm: 60)])
        let overlap = SavedSession(id: UUID(),
                                   start: start.addingTimeInterval(30 * 60),
                                   end: start.addingTimeInterval(90 * 60),
                                   label: "Overlap",
                                   points: [SavedSession.Point(t: 0, bpm: 60)])
        let outside = SavedSession(id: UUID(),
                                   start: start.addingTimeInterval(4 * 60 * 60),
                                   end: start.addingTimeInterval(5 * 60 * 60),
                                   label: "Outside",
                                   points: [SavedSession.Point(t: 0, bpm: 60)])

        XCTAssertEqual(SessionStore.confirmedSleepSensorCoverage(from: [first, overlap, outside],
                                                                  start: start,
                                                                  end: start.addingTimeInterval(2 * 60 * 60)),
                       90 * 60,
                       accuracy: 0.001)
    }

    func testFragmentedAggregateFallbackIsSuppressed() {
        XCTAssertTrue(SessionStore.aggregateHRStageFallbackHasDenseCoverage(duration: 7 * 60 * 60,
                                                                             span: 8 * 60 * 60))
        XCTAssertFalse(SessionStore.aggregateHRStageFallbackHasDenseCoverage(duration: 200 * 60,
                                                                              span: 602 * 60))

        let aggregate = segment(0, 602 * 60, .awake, id: "aggregate-hr-stale")
        let fragmented = sleep(duration: 200 * 60,
                               span: 602 * 60,
                               segments: [aggregate])
        XCTAssertTrue(SessionStore.fragmentedAggregateHRStagesAreUnsupported(fragmented))
    }

    func testNoGrowthAdjustedSleepRecomputesOrClearsStaleStages() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func backfillConfirmedSleepStagesFromSessions"))
        let end = try XCTUnwrap(source.range(of: "private static func confirmedSleepStagesCoverSleep", range: start.upperBound..<source.endIndex))
        let backfill = String(source[start.lowerBound..<end.lowerBound])
        let refresh = try XCTUnwrap(backfill.range(of: "refreshedUserAdjustedSleepEvidenceIfNeeded"))
        let adjustedGuard = try XCTUnwrap(backfill.range(of: "if sleep.source.hasPrefix(\"user_adjusted_\")"))

        XCTAssertLessThan(refresh.lowerBound, adjustedGuard.lowerBound)
        XCTAssertTrue(backfill.contains("hasRecoveredEpochOverlap"))
        // The user-adjusted missing-motion clear branch (the reason= breadcrumb
        // log was removed in f8d9acc9; the guard + clear action are the invariant).
        XCTAssertTrue(backfill.contains("if !hasRecoveredEpochOverlap,"))
        XCTAssertTrue(backfill.contains("fragmentedAggregateHRStagesAreUnsupported"))
        // Stale stages are cleared, not fabricated: the clear action writes nil.
        XCTAssertTrue(backfill.contains("stageSegments: nil"))
    }

    func testAdjustedEvidenceRefreshPreservesUserWindowAndOwnership() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private nonisolated static func refreshedUserAdjustedSleepEvidenceIfNeeded("))
        let end = try XCTUnwrap(source.range(of: "private func backfillConfirmedSleepStagesFromSessions", range: start.upperBound..<source.endIndex))
        let refreshPath = String(source[start.lowerBound..<end.lowerBound])

        for token in [
            "start: sleep.start",
            "end: sleep.end",
            "source: sleep.source",
            "confidence: sleep.confidence",
            "motionProvenance.hasRecoveredEpochs",
            "motionSource: motionSource",
            "motionValidated: motionValidated",
            "eventTimeZoneIdentifier: sleep.eventTimeZoneIdentifier",
        ] {
            XCTAssertTrue(refreshPath.contains(token), "Missing ownership token: \(token)")
        }
        XCTAssertFalse(refreshPath.contains("applySleepExtend"))
    }

    func testAdjustedSleepSavePathAppliesIntegrityGateBeforePersistence() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func confirmSleepWindow(start: Date,"))
        let end = try XCTUnwrap(
            source.range(of: "func adjustConfirmedSleepWindow(existing:", range: start.upperBound..<source.endIndex)
        )
        let savePath = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(savePath.contains("AtriaSleepStageIntegrity.validates(stageSegments, for: staged)"))
        XCTAssertTrue(savePath.contains("Self.copyConfirmedSleep(staged, stageSegments: nil)"))
        XCTAssertTrue(savePath.contains("remaining.append(confirmed)"))
    }

    private let start = Date(timeIntervalSinceReferenceDate: 805_316_709)

    private func sleep(duration: TimeInterval,
                       span: TimeInterval,
                       segments: [SleepStageSegment]) -> UserConfirmedSleep {
        UserConfirmedSleep(id: "stage-integrity",
                           createdAt: start.addingTimeInterval(span + 60),
                           start: start,
                           end: start.addingTimeInterval(span),
                           source: "auto_confirmed_sleep",
                           confidence: "medium",
                           sessions: 7,
                           samples: 7_719,
                           avgHR: 66,
                           peakHR: 108,
                           restingHR: 55,
                           hrv: 67,
                           hrvWindowCount: 5,
                           duration: duration,
                           span: span,
                           reason: "fragmented overnight fixture",
                           motionSource: "historical_gravity",
                           motionValidated: true,
                           stageSegments: segments,
                           eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private func segment(_ offset: TimeInterval,
                         _ duration: TimeInterval,
                         _ stage: SleepStageKind,
                         id: String) -> SleepStageSegment {
        SleepStageSegment(id: id,
                          start: start.addingTimeInterval(offset),
                          end: start.addingTimeInterval(offset + duration),
                          stage: stage)
    }

    func testFragmentedMorningEvidenceRejectsStagesPaintedAcrossUnsupportedGaps() {
        let span: TimeInterval = 19_412
        let segments = [
            segment(0, 1_800, .awake, id: "awake"),
            segment(1_800, 5_400, .light, id: "light"),
            segment(7_200, 9_600, .rem, id: "rem"),
            segment(16_800, 2_612, .sws, id: "sws"),
        ]
        let record = sleep(duration: 9_309, span: span, segments: segments)

        XCTAssertFalse(AtriaSleepStageIntegrity.validates(segments, for: record))
    }

    func testDenseTimelineAllowsAwakeTimeWhileNonAwakeFitsCreditedSleep() {
        let segments = [
            segment(0, 900, .awake, id: "awake"),
            segment(900, 4_500, .light, id: "light"),
            segment(5_400, 1_800, .rem, id: "rem"),
        ]
        let record = sleep(duration: 6_300, span: 7_200, segments: segments)

        XCTAssertTrue(AtriaSleepStageIntegrity.validates(segments, for: record))
        XCTAssertEqual(record.effectiveSleepDuration, 6_300, accuracy: 0.001,
                       "all valid staged sleeps use non-awake time as total sleep time")
    }

    func testNinetySecondPlusUnsupportedGapFailsEvenWithNearFullCoverage() {
        let segments = [
            segment(0, 3_600, .light, id: "before-gap"),
            segment(3_720, 3_480, .rem, id: "after-gap"),
        ]
        let record = sleep(duration: 7_080, span: 7_200, segments: segments)

        XCTAssertGreaterThan(segments.reduce(0) { $0 + $1.duration } / record.span, 0.95)
        XCTAssertFalse(AtriaSleepStageIntegrity.validates(segments, for: record))
    }

    func testDuplicateOrOverlappingStageSegmentsFailClosed() {
        let duplicate = [
            segment(0, 3_600, .light, id: "same"),
            segment(3_600, 3_600, .rem, id: "same")
        ]
        XCTAssertFalse(AtriaSleepStageIntegrity.validates(
            duplicate,
            for: sleep(duration: 7_200, span: 7_200, segments: duplicate)
        ))

        let overlapping = [
            segment(0, 4_000, .light, id: "first"),
            segment(3_600, 3_600, .rem, id: "second")
        ]
        XCTAssertFalse(AtriaSleepStageIntegrity.validates(
            overlapping,
            for: sleep(duration: 7_200, span: 7_200, segments: overlapping)
        ))
    }

    func testHistoryNightSuppressesStagePreviewWhenCreditedSleepDoesNotSupportIt() {
        let span: TimeInterval = 36_170
        let segments = [
            segment(0, 3_600, .awake, id: "awake"),
            segment(3_600, 10_000, .light, id: "light"),
            segment(13_600, 10_000, .rem, id: "rem"),
            segment(23_600, 12_570, .deep, id: "deep"),
        ]
        let night = SleepHistorySnapshot.Night(
            id: "adjusted-night",
            day: start,
            start: start,
            end: start.addingTimeInterval(span),
            duration: 12_026,
            restingHR: 55,
            hrv: 67,
            respiratoryRate: 14.2,
            sleepEfficiency: 0.33,
            confidence: "user_adjusted_motion_validated",
            source: "user_adjusted_sleep",
            confirmed: true,
            stageSegments: segments,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )

        XCTAssertTrue(night.displayStageSegments.isEmpty)
        XCTAssertEqual(night.stageEvidence, .none)
    }

    func testEditorStageSharesNormalizeAgainstFullStagedWindow() {
        let segments = [
            segment(0, 206, .awake, id: "awake"),
            segment(206, 15, .light, id: "light"),
            segment(221, 30, .rem, id: "rem"),
            segment(251, 50, .deep, id: "deep"),
        ]

        let shares = AtriaSleepStagePresentation.shares(for: segments)

        XCTAssertEqual(shares.reduce(0) { $0 + $1.percent }, 100)
        XCTAssertEqual(shares.first(where: { $0.stage == .awake })?.percent, 68)
        XCTAssertEqual(shares.first(where: { $0.stage == .light })?.percent, 5)
        XCTAssertEqual(shares.first(where: { $0.stage == .rem })?.percent, 10)
        XCTAssertEqual(shares.first(where: { $0.stage == .deep })?.percent, 17)
    }

    func testReviewSheetUsesLaneHypnogramInsteadOfFlatStageStrip() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaManualSleepSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private struct AtriaManualSleepHypnogram"))
        XCTAssertTrue(source.contains("Text(\"Stages · Hypnogram\")"))
        XCTAssertTrue(source.contains("AtriaManualSleepHypnogram(segments: night.displayStageSegments"))
        XCTAssertTrue(source.contains("AtriaSleepStageHypnogram.normalizedRange(for: segment"))
        XCTAssertFalse(source.contains("proxy.size.width * CGFloat(segment.duration / total)"))
    }

    func testManualSleepEditorKeepsRelatedControlsCompactAndStageDetailsOptional() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaManualSleepSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private var editorCard: some View"))
        XCTAssertTrue(source.contains("Text(\"Sleep details\")"))
        XCTAssertTrue(source.contains("DisclosureGroup(isExpanded: $showsStageMethodology)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"Duration \\(durationText). \\(validationText)\")"))
        XCTAssertFalse(source.contains("private var typeCard: some View"))
        XCTAssertFalse(source.contains("private var timeCard: some View"))
        XCTAssertFalse(source.contains("private var durationCard: some View"))
        XCTAssertFalse(source.contains("private var stageFooterNote: some View"))
    }

    func testSegmentOutsideConfirmedWindowFailsClosed() {
        let segments = [segment(-60, 3_600, .light, id: "outside")]
        let record = sleep(duration: 3_600, span: 3_600, segments: segments)

        XCTAssertFalse(AtriaSleepStageIntegrity.validates(segments, for: record))
    }

    func testHypnogramPreservesWallClockGapBeforeSegment() throws {
        let timelineEnd = start.addingTimeInterval(7_200)
        let lateSegment = segment(3_600, 1_800, .rem, id: "late")

        let range = try XCTUnwrap(AtriaSleepStageHypnogram.normalizedRange(for: lateSegment,
                                                                          timelineStart: start,
                                                                          timelineEnd: timelineEnd))
        XCTAssertEqual(range.lowerBound, 0.5, accuracy: 0.0001)
        XCTAssertEqual(range.upperBound, 0.75, accuracy: 0.0001)
    }

    func testDisturbanceUsesStagedTimelineInsteadOfCreditedDuration() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaOverviewSections.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var sleepDisturbanceDirection"))
        let end = try XCTUnwrap(source.range(of: "private var sleepHeroState", range: start.lowerBound..<source.endIndex))
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(method.contains("latest.displayStageSegments.reduce"))
        XCTAssertTrue(method.contains("latest.stageDuration(.awake) / stagedDuration"))
        XCTAssertFalse(method.contains("/ max(latest.duration"))
    }

    func testHealthKitAutoSleepExportRequiresValidatedIntegrityCheckedStages() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/HealthKitExporter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func confirmedSleepSamples"))
        let end = try XCTUnwrap(source.range(of: "private func healthKitSleepValue", range: start.lowerBound..<source.endIndex))
        let method = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(method.contains("let isUserAuthored"))
        XCTAssertTrue(method.contains("sleep.source == \"validated_sleep_stages\""))
        XCTAssertTrue(method.contains("AtriaSleepStageIntegrity.validates(segments, for: sleep)"))
        XCTAssertTrue(method.contains("else { return [] }"))
    }
}
