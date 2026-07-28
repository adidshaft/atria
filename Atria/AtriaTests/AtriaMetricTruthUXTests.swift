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
        XCTAssertEqual(disconnected?.title, "Last known · current cycle")
        XCTAssertEqual(disconnected?.allowsRetry, true)

        let connecting = AtriaHealthConnectionEvidencePresentation.notice(
            status: .connecting,
            hasEvidence: true
        )
        XCTAssertEqual(connecting?.title, "Reconnecting · saved current cycle")
        XCTAssertEqual(connecting?.allowsRetry, false)

        let poweredOff = AtriaHealthConnectionEvidencePresentation.notice(
            status: .poweredOff,
            hasEvidence: true
        )
        XCTAssertEqual(poweredOff?.title, "Bluetooth off · saved current cycle")
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
            "return \"Today so far · verified\""
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
}
