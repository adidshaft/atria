import XCTest
@testable import Atria

/// 2026-08-20 (widget-sync W2-A, fixes 3–6).
/// RC3: every patch lane advanced `createdAt`, so the extension's 6h stale
/// disclosure could be silenced by a step receipt that never recomputed
/// recovery — the new `stableEvidenceRefreshedAt` is owned by the full
/// publisher alone and carried unchanged by every partial lane.
/// RC4: the extension re-derived step/strain display text and drifted from
/// the in-app cards — the snapshot now carries app-rendered strings
/// (§13.6 pre-render pattern), display-only, following the family they
/// describe through every patch lane.
/// RC5: the live-source step value claimed currency for 90s while the app's
/// own model stops claiming it at 15s.
/// RC6: `invalidateBatteryProjection` reloaded around the coalescer, leaving
/// the reload ledger stale.
/// All fixtures are anchored after 2026-08-06 (device-use-journal rule).
@MainActor
final class AtriaWidgetStableEvidencePreRenderTests: XCTestCase {
    /// 2026-08-16T02:13:20Z — after the 2026-08-06 fixture anchor floor.
    private let base = Date(timeIntervalSince1970: 1_787_000_000)

    private func snapshot(steps: Int?,
                          stepsCapturedAt: Date?,
                          heartRate: Int? = 72,
                          heartRateCapturedAt: Date? = nil,
                          strain: Double = 4.2) -> WidgetSnapshot {
        WidgetSnapshot(schema: 4,
                       createdAt: stepsCapturedAt ?? base,
                       recoveryPercent: 61,
                       recoveryConfidence: "personal_baseline",
                       recoveryDetail: "Saved",
                       strain: strain,
                       restingHR: 59,
                       hrvRMSSD: 48,
                       hrvState: "personal_baseline",
                       maxHR: 190,
                       sleepHours: 7.5,
                       steps: steps,
                       stepsAreEstimated: false,
                       stepsCapturedAt: stepsCapturedAt,
                       dailyStepGoal: 8_000,
                       heartRate: heartRate,
                       heartRateCapturedAt: heartRateCapturedAt ?? stepsCapturedAt,
                       heartRateZoneIndex: 2,
                       heartRateZoneName: "Fat burn",
                       batteryLevel: 43,
                       batteryChargeStatus: "notCharging",
                       batteryChargeText: "Not charging",
                       layoutGlanceMetrics: ["steps", "strain", "bpm"],
                       layoutRingCenterMetric: "recovery",
                       layoutLegendStatStyle: "value",
                       layoutAccent: "mint",
                       storage: "test",
                       appGroupEnabled: true,
                       widgetTargetPresent: true,
                       complicationTargetPresent: true)
    }

    private func durableProjection(
        source: String,
        cycleStart: Date,
        receiptCapturedAt: Date?,
        steps: Int?,
        coverage: Double = 0.75,
        stepsValueText: String? = nil,
        stepsStatusText: String? = nil
    ) -> WidgetSnapshotPublisher.DurableStepProjection {
        .init(
            authorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            sourceIdentifier: source,
            cycleStart: cycleStart,
            cycleExpiresAt: cycleStart.addingTimeInterval(86_400),
            receiptCapturedAt: receiptCapturedAt,
            receiptContentRevision: receiptCapturedAt == nil
                ? nil : String(repeating: "a", count: 64),
            displayedReceiptContentRevision: steps == nil
                ? nil : String(repeating: "a", count: 64),
            receiptInvalidatesIndependentPartial: false,
            steps: steps,
            stepsAreEstimated: steps == nil ? nil : true,
            stepsCapturedAt: steps == nil ? nil : receiptCapturedAt,
            stepsSource: steps == nil ? nil : "verifiedCanonical",
            stepsCompleteness: steps == nil ? nil : "partial",
            stepsCoverageFraction: steps == nil ? nil : coverage,
            priorCycleSteps: nil,
            priorCycleEndedAt: nil,
            stepsValueText: steps == nil ? nil : stepsValueText,
            stepsStatusText: steps == nil ? nil : stepsStatusText
        )
    }

    // MARK: - RC3: stable-evidence clock survives every patch lane

    /// The plan's fixture: a durable step patch seven hours after the last
    /// full publish must NOT clear (or renew) the stale disclosure — only a
    /// full publish owns that clock.
    func testDurableStepPatchAtHourSevenDoesNotTouchTheStaleClock() throws {
        let source = UUID().uuidString
        let cycleStart = base
        var current = snapshot(steps: 1_976,
                               stepsCapturedAt: base.addingTimeInterval(800))
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.72
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = base.addingTimeInterval(800)
        current.stableEvidenceRefreshedAt = base
        current.stepsValueText = "≥1976"
        current.stepsStatusText = "Counted through 08:00"

        let sevenHoursLater = base.addingTimeInterval(7 * 3_600)
        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: sevenHoursLater.addingTimeInterval(-60),
                    steps: 2_050,
                    coverage: 0.85,
                    stepsValueText: "≥2050",
                    stepsStatusText: "Counted through 09:12"
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: sevenHoursLater
            )
        )

        XCTAssertEqual(patched.stableEvidenceRefreshedAt, base,
                       "a receipt patch must not clear or renew the stale line")
        XCTAssertEqual(patched.createdAt, sevenHoursLater,
                       "the delivery clock may advance; the stable clock may not")
        XCTAssertEqual(patched.steps, 2_050)
        XCTAssertEqual(patched.stepsValueText, "≥2050",
                       "the pre-rendered strings follow the rewritten family")
        XCTAssertEqual(patched.stepsStatusText, "Counted through 09:12")
    }

    func testLiveWorkoutPatchCarriesTheStableClockUnchanged() {
        var current = snapshot(steps: 1_000,
                               stepsCapturedAt: base.addingTimeInterval(100))
        current.stableEvidenceRefreshedAt = base

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: base.addingTimeInterval(3_600),
            heartRate: 120,
            heartRateCapturedAt: base.addingTimeInterval(3_600),
            steps: 1_050,
            stepsAreEstimated: true,
            stepsCapturedAt: base.addingTimeInterval(3_600),
            strain: current.strain,
            batteryLevel: 41,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.stableEvidenceRefreshedAt, base)
    }

    func testOnlyTheFullPublishOwnsTheStableEvidenceClock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let publisher = try String(
            contentsOf: root.appendingPathComponent("Atria/WidgetSnapshot.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(
            publisher.components(
                separatedBy: "snapshot.stableEvidenceRefreshedAt = now"
            ).count - 1,
            1,
            "exactly one writer: the full stable publish"
        )
        XCTAssertTrue(publisher.contains(
            "carried.stableEvidenceRefreshedAt = current.stableEvidenceRefreshedAt"
        ), "every carrying lane preserves the clock as one unit")

        let widget = try String(
            contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(widget.contains(
            "snapshot.stableEvidenceRefreshedAt ?? snapshot.createdAt"
        ), "the stale disclosure ages from the stable clock, createdAt only "
            + "as legacy fallback")
    }

    // MARK: - RC6: battery invalidation keeps the reload ledger truthful

    func testBatteryInvalidationUpdatesReloadLedgerAndPreservesDisplayFields() throws {
        let suite = "AtriaWidgetStableEvidencePreRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored = snapshot(steps: 1_976,
                              stepsCapturedAt: base.addingTimeInterval(500))
        stored.stableEvidenceRefreshedAt = base
        stored.stepsValueText = "≥1976"
        stored.stepsStatusText = "Counted through 08:00"
        stored.strainValueText = "≥ 4.2"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(stored),
                     forKey: "atria.widgetSnapshot.v1")

        let beforeInvalidation = Date()
        WidgetSnapshotPublisher.invalidateBatteryProjection(defaults: defaults)

        let data = try XCTUnwrap(
            defaults.data(forKey: "atria.widgetSnapshot.v1")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sanitized = try decoder.decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(sanitized.batteryLevel)
        XCTAssertEqual(sanitized.stableEvidenceRefreshedAt, base,
                       "a battery dispute is not a stable rebuild")
        XCTAssertEqual(sanitized.stepsValueText, "≥1976")
        XCTAssertEqual(sanitized.stepsStatusText, "Counted through 08:00")
        XCTAssertEqual(sanitized.strainValueText, "≥ 4.2")

        #if canImport(WidgetKit)
        let ledger = try XCTUnwrap(
            WidgetSnapshotPublisher.lastDeliveredTimelineReloadLedger,
            "the dispute reload must go through the delivery ledger"
        )
        XCTAssertNil(ledger.snapshot.batteryLevel,
                     "the ledger must record the sanitized snapshot")
        XCTAssertEqual(ledger.snapshot.stepsValueText, "≥1976")
        XCTAssertGreaterThanOrEqual(ledger.deliveredAt, beforeInvalidation)
        #endif
    }

    // MARK: - RC4: pre-rendered strings follow their families

    func testAcceptedLiveStepPatchInstallsItsOwnRenderedStrings() {
        var current = snapshot(steps: 1_000,
                               stepsCapturedAt: base.addingTimeInterval(100))
        current.stepsValueText = "1000"
        current.stepsStatusText = "Today so far · live"

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: base.addingTimeInterval(200),
            heartRate: 120,
            heartRateCapturedAt: base.addingTimeInterval(200),
            steps: 1_050,
            stepsAreEstimated: false,
            stepsCapturedAt: base.addingTimeInterval(200),
            stepsSource: "live",
            stepsCompleteness: "partial",
            stepsAuthorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            stepsValueText: "1050",
            stepsStatusText: "Today so far · live",
            strain: current.strain,
            batteryLevel: 41,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.steps, 1_050)
        XCTAssertEqual(patched.stepsValueText, "1050")
        XCTAssertEqual(patched.stepsStatusText, "Today so far · live")
    }

    func testRejectedLiveStepPatchKeepsTheDeliveredRowsStrings() {
        var current = snapshot(steps: 1_976,
                               stepsCapturedAt: base.addingTimeInterval(900))
        current.stepsValueText = "≥1976"
        current.stepsStatusText = "Counted through 08:00"

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: base.addingTimeInterval(1_000),
            heartRate: 120,
            heartRateCapturedAt: base.addingTimeInterval(1_000),
            steps: 1_500,
            stepsAreEstimated: false,
            // Older than the delivered row's clock: the patch must not win.
            stepsCapturedAt: base.addingTimeInterval(400),
            stepsValueText: "1500",
            stepsStatusText: "Today so far · live",
            strain: current.strain,
            batteryLevel: 41,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.steps, 1_976)
        XCTAssertEqual(patched.stepsValueText, "≥1976",
                       "a rejected patch may not relabel the row it failed to replace")
        XCTAssertEqual(patched.stepsStatusText, "Counted through 08:00")
    }

    func testLivePatchClearsStrainValueTextOnlyWhenTheAggregateMoves() {
        var current = snapshot(steps: 100,
                               stepsCapturedAt: base.addingTimeInterval(100),
                               strain: 4.2)
        current.strainValueText = "≥ 4.2"

        let unchanged = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: base.addingTimeInterval(200),
            heartRate: 90,
            heartRateCapturedAt: base.addingTimeInterval(200),
            steps: nil,
            stepsAreEstimated: false,
            stepsCapturedAt: nil,
            strain: 4.2,
            batteryLevel: 41,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )
        XCTAssertEqual(unchanged.strainValueText, "≥ 4.2",
                       "an unmoved aggregate keeps its app-rendered text")

        let moved = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: base.addingTimeInterval(200),
            heartRate: 90,
            heartRateCapturedAt: base.addingTimeInterval(200),
            steps: nil,
            stepsAreEstimated: false,
            stepsCapturedAt: nil,
            strain: 6.8,
            batteryLevel: 41,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )
        XCTAssertNil(moved.strainValueText,
                     "a stale pre-render can never describe a patched number")
    }

    func testUnresolvedReceiptRewriteClearsPreRenderedStepStrings() throws {
        let source = UUID().uuidString
        let cycleStart = base
        var current = snapshot(steps: 1_500,
                               stepsCapturedAt: base.addingTimeInterval(800))
        current.stepsSource = "verifiedCanonical"
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = base.addingTimeInterval(800)
        current.stepsValueText = "1500"
        current.stepsStatusText = "Counted through 08:00"

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: base.addingTimeInterval(2_000),
                    steps: nil
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: base.addingTimeInterval(2_100)
            )
        )

        XCTAssertNil(patched.steps)
        XCTAssertNil(patched.stepsValueText,
                     "no value, no value text — legacy fallback renders the "
                     + "nil-state disclosures")
        XCTAssertNil(patched.stepsStatusText)
    }

    func testBroadPublishMergeKeepsStringsWithTheirFamilies() {
        let source = UUID().uuidString
        let cycleStart = base
        var current = snapshot(steps: 1_976,
                               stepsCapturedAt: base.addingTimeInterval(1_100))
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = base.addingTimeInterval(1_100)
        current.stepsValueText = "≥1976"
        current.stepsStatusText = "Counted through 08:18"
        current.strainValueText = "≥ 4.2"
        current.stableEvidenceRefreshedAt = base

        var staleBroad = snapshot(steps: 1_500,
                                  stepsCapturedAt: base.addingTimeInterval(900),
                                  strain: 7.1)
        staleBroad.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        staleBroad.stepsReceiptSourceIdentifier = source
        staleBroad.stepsReceiptCycleStart = cycleStart
        staleBroad.stepsReceiptCapturedAt = base.addingTimeInterval(900)
        staleBroad.stepsValueText = "1500"
        staleBroad.stepsStatusText = "Counted through 08:15"
        staleBroad.strainValueText = "7.1"
        staleBroad.stableEvidenceRefreshedAt = base.addingTimeInterval(1_200)

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: staleBroad,
                current: current
            )

        XCTAssertEqual(merged.steps, 1_976)
        XCTAssertEqual(merged.stepsValueText, "≥1976",
                       "the preserved step family keeps the strings that "
                       + "describe it")
        XCTAssertEqual(merged.stepsStatusText, "Counted through 08:18")
        XCTAssertEqual(merged.strainValueText, "7.1",
                       "strain belongs to the fresh broad candidate")
        XCTAssertEqual(merged.stableEvidenceRefreshedAt,
                       base.addingTimeInterval(1_200),
                       "the broad candidate IS a stable rebuild; its clock wins")
    }

    func testChangedPreRenderedStringForcesImmediateReloadButCaptureClockStaysCoalesced() {
        let now = base
        var previous = snapshot(steps: 1_000,
                                stepsCapturedAt: now.addingTimeInterval(-30))
        previous.stepsStatusText = "Counted through 08:00"

        var changedText = previous
        changedText.stepsStatusText = "Counted through 08:01"
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: now,
            snapshot: changedText,
            now: now.addingTimeInterval(1)
        ), 0, "a changed app-rendered string is a visible semantic transition")

        var changedClock = previous
        changedClock.stepsCapturedAt = now.addingTimeInterval(-20)
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: now,
            snapshot: changedClock,
            now: now.addingTimeInterval(1)
        ), 59, "a bare capture-clock advance still rides the 60s sensor lane "
            + "— the reload budget is unchanged")
    }

    // MARK: - RC4: schema stays additive-optional

    func testLegacyPayloadWithoutNewKeysStillDecodes() throws {
        let legacyJSON = """
        {
          "schema": 4,
          "createdAt": "2026-08-16T06:00:00Z",
          "recoveryPercent": 61,
          "recoveryConfidence": "personal_baseline",
          "recoveryDetail": "Saved",
          "strain": 4.2,
          "restingHR": 59,
          "hrvRMSSD": 48,
          "hrvState": "personal_baseline",
          "maxHR": 190,
          "sleepHours": 7.5,
          "steps": 1000,
          "heartRate": 72,
          "storage": "test",
          "appGroupEnabled": false,
          "widgetTargetPresent": true,
          "complicationTargetPresent": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self,
                                         from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.stableEvidenceRefreshedAt)
        XCTAssertNil(decoded.stepsValueText)
        XCTAssertNil(decoded.stepsStatusText)
        XCTAssertNil(decoded.strainValueText)
    }

    // MARK: - RC4: Siri surfaces prefer the app-rendered strain string

    func testSiriPrefersAppRenderedStrainStringAndTranslatesTheQualifier() {
        XCTAssertEqual(AtriaIntentMetricPresentation.strainCompact(
            value: 3.42,
            detail: "Partial · sparse HR",
            appRenderedValueText: "≥ 3.4"
        ), "≥ 3.4")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainSpoken(
            value: 3.42,
            detail: "Partial · sparse HR",
            appRenderedValueText: "≥ 3.4"
        ), "at least 3.4", "the lower-bound qualifier must stay speakable")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainCompact(
            value: 12.37,
            detail: "Current cycle",
            appRenderedValueText: "12.4"
        ), "12.4")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainSpoken(
            value: 12.37,
            detail: "Current cycle",
            appRenderedValueText: "12.4"
        ), "12.4")
        // Legacy payloads without the pre-render keep today's derivation.
        XCTAssertEqual(AtriaIntentMetricPresentation.strainCompact(
            value: 3.42,
            detail: "Partial · sparse HR"
        ), "≥ 3.4")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainSpoken(
            value: 3.42,
            detail: "Partial · sparse HR"
        ), "at least 3.4")
    }

    // MARK: - RC4/RC5: extension preference and step-value claim window

    func testExtensionPrefersAppRenderedStringsWithHonestCurrencyGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(widget.contains(
            "let text = s.stepsValueText ?? atriaStepValueText(s, steps: steps)"
        ), "app-rendered value first, legacy derivation as fallback")
        XCTAssertTrue(widget.contains(
            "if let strainValueText = s.strainValueText { return strainValueText }"
        ))
        XCTAssertGreaterThanOrEqual(
            widget.components(separatedBy: "atriaPreRenderedStepStatus(").count - 1,
            3,
            "both fresh status paths must route through the currency-gated "
            + "pre-render helper"
        )
        XCTAssertTrue(widget.contains(
            "localizedCaseInsensitiveContains(\"so far\")"
        ), "a pre-rendered CURRENCY claim is honored only while its evidence "
            + "clock still supports it")
    }

    func testLiveSourceStepValueClaimWindowMatchesTheAppModel() throws {
        XCTAssertEqual(AtriaDailyStepPresentation.liveEvidenceMaximumAge, 15,
                       "the widget's claim-window constant mirrors this value")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(widget.contains(
            "private let atriaLiveSourceStepValueClaimWindow: TimeInterval = 15"
        ))
        // RC5: past the claim window the live-source VALUE line wears its
        // capture frontier; the 90s freshness survives only as delivery slack.
        XCTAssertTrue(widget.contains(
            "> atriaLiveSourceStepValueClaimWindow"
        ))
        XCTAssertTrue(widget.contains(
            "return \"\\(text) · \\(atriaCaptureTimeText(capturedAt))\""
        ))
        // Both visible transitions land as exact timeline entries: the claim
        // boundary and the existing delivery-slack expiry.
        XCTAssertTrue(widget.contains(
            "expirySources.append((snapshot?.stepsCapturedAt,\n                                  atriaLiveSourceStepValueClaimWindow))"
        ))
        XCTAssertTrue(widget.contains(
            "expirySources.append((snapshot?.stepsCapturedAt, atriaStaticStepFreshness))"
        ), "the 90s delivery-slack expiry entry must still land")
    }
}
