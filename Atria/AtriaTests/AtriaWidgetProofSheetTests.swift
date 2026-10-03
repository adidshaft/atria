import XCTest
@testable import Atria

final class AtriaWidgetProofSheetTests: XCTestCase {
    func testDiagnosticsAreIndependentOfUserMetricValues() {
        let writtenAt = Date(timeIntervalSince1970: 1_725_000_000)
        let first = makeSnapshot(
            writtenAt: writtenAt,
            recovery: 12,
            strain: 1.2,
            restingHeartRate: 48,
            hrv: 72,
            heartRate: 61
        )
        let second = makeSnapshot(
            writtenAt: writtenAt,
            recovery: 94,
            strain: 19.8,
            restingHeartRate: 83,
            hrv: 21,
            heartRate: 177
        )

        XCTAssertEqual(
            AtriaWidgetProofDiagnostics(
                snapshot: first,
                layoutConfig: .default
            ),
            AtriaWidgetProofDiagnostics(
                snapshot: second,
                layoutConfig: .default
            ),
            "The app-side diagnostics must never become a second metric renderer"
        )
    }

    func testAvailableSnapshotReportsOnlyDeliveryAndTargetMetadata() {
        let writtenAt = Date(timeIntervalSince1970: 1_725_000_000)
        let snapshot = makeSnapshot(
            writtenAt: writtenAt,
            recovery: 61,
            strain: 4.2,
            restingHeartRate: 59,
            hrv: nil,
            heartRate: 72
        )

        let diagnostics = AtriaWidgetProofDiagnostics(
            snapshot: snapshot,
            layoutConfig: .default
        )

        XCTAssertTrue(diagnostics.hasSnapshot)
        XCTAssertEqual(diagnostics.snapshotWrittenAt, writtenAt)
        XCTAssertEqual(diagnostics.schemaText, "4")
        XCTAssertEqual(diagnostics.storageText, "app_group_userdefaults")
        XCTAssertEqual(diagnostics.appGroupText, "Available")
        XCTAssertEqual(diagnostics.homeScreenTargetText, "Available")
        XCTAssertEqual(diagnostics.lockScreenTargetText, "Available")
        XCTAssertEqual(diagnostics.configuredOrderText, "sleep / strain / hrv")
        XCTAssertEqual(diagnostics.ringCenterText, "sleep")
        XCTAssertEqual(diagnostics.legendStyleText, "value")
    }

    func testMissingSnapshotHasTerminalDiagnosticState() {
        let diagnostics = AtriaWidgetProofDiagnostics(
            snapshot: nil,
            layoutConfig: .default
        )

        XCTAssertFalse(diagnostics.hasSnapshot)
        XCTAssertNil(diagnostics.snapshotWrittenAt)
        XCTAssertEqual(diagnostics.schemaText, "--")
        XCTAssertEqual(diagnostics.storageText, "No shared payload")
        XCTAssertEqual(diagnostics.appGroupText, "Unknown")
        XCTAssertEqual(diagnostics.homeScreenTargetText, "Unknown")
        XCTAssertEqual(diagnostics.lockScreenTargetText, "Unknown")
        XCTAssertFalse(diagnostics.configuredOrderText.isEmpty)
    }

    /// 2026-09-03: on a device with no payload the sheet reported "Unknown"
    /// for all three surfaces — on the very screen opened to find out — and
    /// told the reader to "Open Atria once", which is the only way to reach
    /// this sheet. The live probe answers for the surfaces whether or not a
    /// payload was ever written.
    @MainActor
    func testMissingSnapshotFallsBackToTheLiveProbe() {
        let live = WidgetSnapshotPublisher.Diagnostics(storage: "app_group_userdefaults",
                                                       appGroupEnabled: true,
                                                       widgetTargetPresent: true,
                                                       complicationTargetPresent: false)
        let diagnostics = AtriaWidgetProofDiagnostics(snapshot: nil,
                                                      layoutConfig: .default,
                                                      live: live)

        XCTAssertFalse(diagnostics.hasSnapshot)
        XCTAssertEqual(diagnostics.appGroupText, "Available")
        XCTAssertEqual(diagnostics.homeScreenTargetText, "Available")
        XCTAssertEqual(diagnostics.lockScreenTargetText, "Unavailable")
        XCTAssertEqual(diagnostics.storageText, "Ready · nothing published yet")
        let detail = diagnostics.missingPayloadDetail ?? ""
        XCTAssertTrue(detail.contains("nothing has been published yet"), detail)
    }

    @MainActor
    func testUnreachableAppGroupIsNamedAsTheCause() {
        let live = WidgetSnapshotPublisher.Diagnostics(storage: "unavailable",
                                                       appGroupEnabled: false,
                                                       widgetTargetPresent: true,
                                                       complicationTargetPresent: true)
        let diagnostics = AtriaWidgetProofDiagnostics(snapshot: nil,
                                                      layoutConfig: .default,
                                                      live: live)

        XCTAssertEqual(diagnostics.appGroupText, "Unavailable")
        XCTAssertEqual(diagnostics.storageText, "App group unavailable")
        let detail = diagnostics.missingPayloadDetail ?? ""
        XCTAssertTrue(detail.contains("cannot reach the shared app group"), detail)
    }

    func testAPayloadThatExistsHasNoMissingDetail() {
        let diagnostics = AtriaWidgetProofDiagnostics(
            snapshot: makeSnapshot(writtenAt: Date(timeIntervalSince1970: 1_725_000_000),
                                   recovery: 61, strain: 4.2,
                                   restingHeartRate: 59, hrv: nil, heartRate: 72),
            layoutConfig: .default
        )
        XCTAssertNil(diagnostics.missingPayloadDetail)
    }

    func testTheImpossibleInstructionIsGone() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWidgetProofSheet.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("Open Atria once to publish a shared payload"),
                       "this sheet can only be opened from inside Atria")
        XCTAssertTrue(source.contains("live: WidgetSnapshotPublisher.diagnostics"),
                      "the sheet passes the live probe")
    }

    func testSheetCannotReintroduceIndependentMetricPresentation() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaWidgetProofSheet.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let forbiddenPresentationTokens = [
            "snapshot?.recoveryPercent",
            "snapshot.recoveryPercent",
            "snapshot?.strain",
            "snapshot.strain",
            "snapshot?.hrvRMSSD",
            "snapshot.hrvRMSSD",
            "snapshot?.restingHR",
            "snapshot.restingHR",
            "snapshot?.heartRate",
            "snapshot.heartRate",
            "snapshot?.sleepHours",
            "snapshot.sleepHours",
            "snapshot?.steps",
            "snapshot.steps",
            "AtriaWidgetProofMetric",
            "recovery >= 67",
            "recovery >= 34",
        ]
        for token in forbiddenPresentationTokens {
            XCTAssertFalse(
                source.contains(token),
                "Widget diagnostics must not contain presentation token: \(token)"
            )
        }
        XCTAssertTrue(source.contains("Widget diagnostics"))
        XCTAssertTrue(source.contains("Does not preview metric values"))
        XCTAssertFalse(source.contains("Widget timeline snapshot ready"))
        XCTAssertFalse(source.contains("Home Screen · medium"))
        XCTAssertFalse(source.contains("Lock Screen accessories"))
    }

    private func makeSnapshot(
        writtenAt: Date,
        recovery: Int?,
        strain: Double,
        restingHeartRate: Int?,
        hrv: Int?,
        heartRate: Int?
    ) -> WidgetSnapshot {
        WidgetSnapshot(
            schema: 4,
            createdAt: writtenAt,
            recoveryPercent: recovery,
            recoveryConfidence: "personal_baseline",
            recoveryDetail: "Current cycle",
            strain: strain,
            restingHR: restingHeartRate,
            hrvRMSSD: hrv,
            hrvState: hrv == nil ? "learning" : "personal_baseline",
            maxHR: 190,
            sleepHours: 7.5,
            steps: 1_234,
            stepsCapturedAt: writtenAt,
            heartRate: heartRate,
            heartRateCapturedAt: writtenAt,
            batteryLevel: 72,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging",
            layoutGlanceMetrics: ["sleep", "strain", "hrv"],
            layoutRingCenterMetric: "sleep",
            layoutLegendStatStyle: "value",
            layoutAccent: "mint",
            storage: "app_group_userdefaults",
            appGroupEnabled: true,
            widgetTargetPresent: true,
            complicationTargetPresent: true
        )
    }
}
