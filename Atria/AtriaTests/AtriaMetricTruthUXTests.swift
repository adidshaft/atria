import XCTest
@testable import Atria

final class AtriaMetricTruthUXTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let testsURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appURL = testsURL.deletingLastPathComponent().appendingPathComponent("Atria")
        return try String(contentsOf: appURL.appendingPathComponent(name),
                          encoding: .utf8)
    }

    func testHealthCurrentCyclePreservesSpecificMissingMetricReasons() {
        let projection = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: nil,
            recoveryDetail: "HRV pending",
            restingHeartRateText: "--",
            hrvValue: "--",
            hrvDetail: "HRV settling"
        )))

        XCTAssertEqual(projection.recoveryValue, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(projection.recoveryDetail, "HRV pending")
        XCTAssertEqual(projection.hrvValue, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(projection.hrvDetail, "HRV settling")
    }

    func testHealthCurrentCycleFallsBackOnlyWhenUpstreamReasonIsGeneric() {
        let projection = AtriaHealthMetricAuthority.resolve(.currentCycle(.init(
            recoveryPercent: nil,
            recoveryDetail: "Learning",
            restingHeartRateText: "--",
            hrvValue: "Learning",
            hrvDetail: "Learning"
        )))

        XCTAssertEqual(projection.recoveryDetail, "Recovery evidence incomplete")
        XCTAssertEqual(projection.hrvDetail, "Needs quiet rest or sleep")
    }

    func testHealthReconnectActionExistsOnlyWhenRetryCanDoWork() {
        XCTAssertNil(AtriaHealthConnectionEvidencePresentation.notice(
            status: .connected,
            hasEvidence: true
        ))
        XCTAssertNil(AtriaHealthConnectionEvidencePresentation.notice(
            status: .disconnected,
            hasEvidence: false
        ))

        let disconnected = AtriaHealthConnectionEvidencePresentation.notice(
            status: .disconnected,
            hasEvidence: true
        )
        XCTAssertEqual(disconnected?.title, "Strap disconnected")  // 2026-08-04 single-carrier: scope lives in the header chip
        XCTAssertEqual(disconnected?.allowsRetry, true)

        let connecting = AtriaHealthConnectionEvidencePresentation.notice(
            status: .connecting,
            hasEvidence: true
        )
        XCTAssertEqual(connecting?.title, "Reconnecting")
        XCTAssertEqual(connecting?.allowsRetry, false)

        let poweredOff = AtriaHealthConnectionEvidencePresentation.notice(
            status: .poweredOff,
            hasEvidence: true
        )
        XCTAssertEqual(poweredOff?.title, "Bluetooth off")
        XCTAssertEqual(poweredOff?.allowsRetry, false)
    }

    func testManualHistoryFeedbackNeverClaimsARejectedRequestIsSyncing() {
        XCTAssertEqual(AtriaManualHistorySyncFeedback.started.title,
                       "Strap history sync started")
        XCTAssertTrue(AtriaManualHistorySyncFeedback.started.detail
            .contains("accepted the transfer request"))
        XCTAssertEqual(AtriaManualHistorySyncFeedback.notStarted.title,
                       "No history sync started")
        XCTAssertTrue(AtriaManualHistorySyncFeedback.notStarted.detail
            .contains("did not start"))
    }

    func testMetricAcquisitionReasonLivesOnMetricAndVO2NamesItsActualBlocker() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("return hero.hrvDetail"))
        XCTAssertTrue(overview.contains("\"Needs quiet rest or sleep\""))
        XCTAssertTrue(overview.contains(
            "\"VO2max unavailable. \\(vo2MaxEstimate.compactStatusText). \\(vo2MaxEstimate.narrative)\""
        ))
    }

    func testSettingsHasNoTimedFakeHistorySyncState() throws {
        let settings = try source("AtriaSettingsView.swift")
        XCTAssertFalse(settings.contains("Syncing from strap…"))
        XCTAssertFalse(settings.contains("@State private var syncTapped"))
        XCTAssertTrue(settings.contains("historySyncFeedback = onSyncMissedData() ? .started : .notStarted"))
    }

    func testUnavailableDetailHeroesUseNeutralNoValuePresentation() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains(
            "guard let percent = recoveryHeroRawPercent else {\n            return AtriaCompactMetricPresentation.noValue"
        ))
        XCTAssertTrue(overview.contains(
            "guard let strainHeroRawValue else {\n            return AtriaCompactMetricPresentation.noValue"
        ))
        XCTAssertFalse(overview.contains(
            "recoveryHeroRawPercent.map { Metrics.recoveryColor(Int($0.rounded())) } ?? Metrics.electricGreen"
        ))
        XCTAssertTrue(overview.contains(
            "guard let latest = preparedHistory.fitnessAge[range]?.last?.value else { return .secondary }"
        ))
    }

    func testConnectionGuideDoesNotPromoteTransportToLivePulse() throws {
        let guide = try source("AtriaHeroConnectionSections.swift")
        XCTAssertTrue(guide.contains(
            "Text(status == .connected ? \"Connected\" : \"Setup\")"
        ))
        XCTAssertFalse(guide.contains(
            "Text(status == .connected ? \"Live\" : \"Setup\")"
        ))
    }

    func testWidgetDoesNotCallAnOpenPhysiologicalCycleComplete() throws {
        let widget = try source("../AtriaWidget/AtriaWidget.swift")
        XCTAssertTrue(widget.contains(
            "if let cycleExpiresAt = snapshot.stepsCycleExpiresAt,\n                   cycleExpiresAt > now"
        ))
        XCTAssertTrue(widget.contains(
            "? \"Today so far · verified\""
        ))
        XCTAssertTrue(widget.contains(
            ": \"Verified through \\(atriaCaptureTimeText(capturedAt))\""
        ))
    }

    func testFallbackHeroDoesNotPromoteBLETransportToLiveSignal() throws {
        let home = try source("AtriaHomeView.swift")
        XCTAssertTrue(home.contains(
            "return \"Strap is connected.\""
        ))
        XCTAssertFalse(home.contains(
            "return \"Live connection is active.\""
        ))
    }

    func testPartialDailyStrainKeepsTextButCannotEarnAQualifiedShareRing() {
        XCTAssertFalse(AtriaDailyShareMetricTruth.strainIsQualified(
            value: "≥ 4.2",
            confidence: "local · partial-day wear"
        ))
        XCTAssertFalse(AtriaDailyShareMetricTruth.strainIsQualified(
            value: "4.2",
            confidence: "provisional · partial sparse HR"
        ))
        XCTAssertFalse(AtriaDailyShareMetricTruth.strainIsQualified(
            value: AtriaCompactMetricPresentation.noValue,
            confidence: "learning"
        ))
        XCTAssertTrue(AtriaDailyShareMetricTruth.strainIsQualified(
            value: "4.2",
            confidence: "personal baseline"
        ))
    }

    func testUnavailableMetricCardsUseNeutralToneAndSpecificReasons() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains(
            "vo2MaxEstimate.value == nil ? .secondary : .blue"
        ))
        XCTAssertTrue(overview.contains(
            "biologicalAgeSummary.isEarlyEstimate"
        ))
        XCTAssertTrue(overview.contains(
            ": .secondary),\n                                  zone: biologicalAgeZone"
        ))
        XCTAssertTrue(overview.contains(
            "decoderAvailable\n                                    ? (skinTemperatureDeviationZone?.tint ?? Metrics.electricRespiratory)\n                                    : .secondary"
        ))
        XCTAssertTrue(overview.contains(
            "hero.recoveryEstimate.percent == nil\n                                        ? AtriaCompactMetricPresentation.noValue"
        ))

        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains(
            "tint: live.vo2MaxEstimate.value == nil\n                                        ? .secondary"
        ))
        XCTAssertTrue(health.contains(
            "guard summary.isReady else { return .secondary }"
        ))
    }

    func testTrendAndSleepDurationLabelsDoNotClaimCircadianRhythm() throws {
        // The "Rhythm" half of this test lived inside
        // AtriaTrendRangeAssessmentCard, one of the unreachable trend-period
        // views removed 2026-08-27 — and it used AtriaTrendActionReadoutCard,
        // removed in the same sweep, as its END BOUNDARY. Two dead structs
        // holding a live-looking assertion between them.
        //
        // Worth naming: three tests in this suite anchor their spans on
        // `private struct` names, so a struct can be kept alive purely by being
        // a test's delimiter. That is a bad reason for code to exist.
        let trend = try source("AtriaTrendChart.swift")
        XCTAssertFalse(trend.contains("assessmentBar(label: \"Rhythm\""),
                       "no surface may claim circadian rhythm")
        XCTAssertFalse(trend.contains("AtriaTrendRangeAssessmentCard"),
                       "the dead assessment card must stay removed")

        // The two POSITIVE assertions here pinned a label inside
        // AtriaDetailRangeLensCard (lines 13124-13315 of the pre-removal file;
        // the label sat at 13182). That card had zero construction sites, and a
        // comment elsewhere in the file already said it "was removed here" —
        // so the label it names never rendered. Verified by brace-matching the
        // original rather than by eye: an earlier attribution of that line to
        // the live AtriaMetricMeaningSheet was wrong, and would have had me
        // report a regression that did not exist.
        //
        // The NEGATIVE assertions are the ones that carry the rule, and they
        // hold across the whole file rather than inside any one card.
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertFalse(overview.contains("Label(\"Sleep rhythm\""),
                       "no surface may claim circadian rhythm")
        XCTAssertFalse(overview.contains(".accessibilityLabel(\"Sleep rhythm."))
        // The DECLARATION, not any mention: a comment at the old render site
        // still records that the card was taken out of the layout, and that
        // history is worth keeping.
        XCTAssertFalse(overview.contains("private struct AtriaDetailRangeLensCard"),
                       "the dead lens card must stay removed")

        XCTAssertTrue(AtriaAboutMetric.sleep.honestyNote.contains(
            "not a clinical sleep study or a measurement of circadian phase"
        ))
    }

    func testUnsupportedSensorCardsNameDecoderLimitationAndKeepNoValue() throws {
        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("detail: AtriaSpO2Copy.decoderNotVerified"))
        XCTAssertTrue(overview.contains("heroState: AtriaSpO2Copy.decoderNotVerified"))
        XCTAssertTrue(overview.contains("heroState: hasReading ? \"vs sleep baseline\" : (decoderAvailable ? \"Learning\" : \"Decoder not verified\")"))
        XCTAssertTrue(overview.contains(
            "AtriaGlanceMetricCard(title: \"Blood oxygen\",\n                                  value: \"--\""
        ))
        XCTAssertFalse(AtriaSpO2Copy.decoderNotVerified.localizedCaseInsensitiveContains("available yet"))

        let settings = try source("AtriaSettingsView.swift")
        XCTAssertTrue(settings.contains("cannot measure an ECG or classify sinus rhythm"))
    }

    func testSleepSufficiencyShowsRecordedSleepAndFrozenNeedNotAnUnexplainedPercent() throws {
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("footnote: sleepPerformanceFootnote"))
        XCTAssertTrue(health.contains("sleepPerformanceSummary("))
        XCTAssertFalse(health.contains("footnote: \"of nightly need\""))
    }

    func testTodayWristTemperatureUsesCanonicalNoValueProjection() throws {
        let today = try source("AtriaTodayScreen.swift")
        let bodyTemperatureStart = try XCTUnwrap(
            today.range(of: "case .bodyTemp:")
        )
        let nextCase = try XCTUnwrap(
            today.range(
                of: "case .trend:",
                range: bodyTemperatureStart.upperBound..<today.endIndex
            )
        )
        let bodyTemperature = String(
            today[bodyTemperatureStart.lowerBound..<nextCase.lowerBound]
        )

        XCTAssertTrue(bodyTemperature.contains(
            "AtriaExperimentalSensorCopy\n                                            .skinTemperatureValue("
        ))
        XCTAssertFalse(bodyTemperature.contains(
            "decoderAvailable ? skinTemp.valueText : \"\\u{2014}\""
        ))
        XCTAssertEqual(
            AtriaExperimentalSensorCopy.skinTemperatureValue(
                summary: .init(
                    latestDeltaCelsius: nil,
                    baselineSessions: 0,
                    candidateFrames: 0,
                    candidateValues: 0
                ),
                decoderAvailable: false
            ),
            AtriaCompactMetricPresentation.noValue
        )
    }

    func testCompactStressConsumersKeepTheCanonicalEvidenceTitle() throws {
        let home = try source("AtriaHomeView.swift")
        XCTAssertTrue(home.contains("let stressEvidenceMode: AtriaStressEvidenceMode?"))
        XCTAssertTrue(home.contains("let stressMetricTitle: String"))
        XCTAssertTrue(home.contains("stressEvidenceMode: stress.evidenceMode"))
        XCTAssertTrue(home.contains("stressMetricTitle: stress.metricTitle"))

        let today = try source("AtriaTodayScreen.swift")
        XCTAssertTrue(today.contains("title: displayHero.stressMetricTitle"))
        XCTAssertTrue(today.contains("stressEvidenceMode: displayHero.stressEvidenceMode"))

        let overview = try source("AtriaOverviewSections.swift")
        XCTAssertTrue(overview.contains("AtriaGlanceMetricCard(title: hero.stressMetricTitle"))
        XCTAssertTrue(overview.contains("lhs.hero.stressEvidenceMode == rhs.hero.stressEvidenceMode"))
        XCTAssertTrue(overview.contains("lhs.hero.stressMetricTitle == rhs.hero.stressMetricTitle"))

        // 2026-08-26: this assertion's subject lived in the orphaned Vitals
        // tab tree (AtriaVitalsTabContent, zero construction sites), removed
        // in that change. AtriaHomeView mounts AtriaHealthScreen for the
        // Vitals tab and always has, so this was guarding UI nobody could
        // open. Recorded rather than silently deleted: it means this behaviour
        // was BUILT AND TESTED but never reached the live screen.
        //
        // UNMIGRATED: the live AtriaHealthScreen has no `stressMetricTitle`
        // consumer at all, so the canonical evidence title that Home, Today and
        // Overview all pass is simply absent from the Vitals tab. Whether to
        // carry it over is a product decision.
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertFalse(health.contains("stressMetricTitle"),
                       "if this starts passing, the title reached Vitals and "
                           + "this assertion should become a positive one")

        let coach = try source("AtriaAICoach.swift")
        XCTAssertTrue(coach.contains("let resolvedTitle = \"Physiological stress\""))
        XCTAssertTrue(coach.contains("\\(resolvedTitle) \\(context.stressText) (HR-only estimate; lower confidence)"))
        XCTAssertFalse(coach.contains("Cardiac arousal \\(context.stressText)"))
    }
}
