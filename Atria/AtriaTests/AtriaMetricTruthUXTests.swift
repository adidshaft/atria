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
        // 2026-08-06: audit fix — dead twin deleted. The hero.hrvDetail and
        // VO2max-unavailable pins lived in the removed legacy Overview readiness
        // section; the surviving acquisition-reason copy lives on the Health
        // screen and is asserted there.
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains("\"Needs quiet rest or sleep\""))
    }

    func testSettingsHasNoTimedFakeHistorySyncState() throws {
        let settings = try source("AtriaSettingsView.swift")
        XCTAssertFalse(settings.contains("Syncing from strap…"))
        XCTAssertFalse(settings.contains("@State private var syncTapped"))
        XCTAssertTrue(settings.contains("historySyncFeedback = onSyncMissedData() ? .started : .notStarted"))
    }

    func testUnavailableDetailHeroesUseNeutralNoValuePresentation() throws {
        // 2026-08-06: audit fix — dead twin deleted. The recoveryHeroRawPercent/
        // strainHeroRawValue no-value pins lived in the removed legacy Overview
        // readiness section; the anti-pattern absence and the live fitness-age
        // guard below still apply.
        let overview = try source("AtriaOverviewSections.swift")
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
        // 2026-08-06: audit fix — dead twin deleted. The five overview pins here
        // (VO2max/biological-age/skin-temp/recovery neutral-tone gating) lived in
        // the removed legacy Overview readiness glance cards; the live Health
        // screen assertions below still guard the behavior.
        let health = try source("AtriaHealthScreen.swift")
        XCTAssertTrue(health.contains(
            "tint: live.vo2MaxEstimate.value == nil\n                                        ? .secondary"
        ))
        XCTAssertTrue(health.contains(
            "guard summary.isReady else { return .secondary }"
        ))
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
}
