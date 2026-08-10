import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

struct WidgetSnapshot: Codable {
    let schema: Int
    var createdAt: Date
    let recoveryPercent: Int?
    let recoveryConfidence: String
    let recoveryDetail: String
    let strain: Double
    /// Evidence qualifier for the numeric day-load value. Current writers use
    /// this to distinguish a partial sparse-HR aggregate from a complete cycle.
    var strainDetail: String? = nil
    /// When the cumulative wake-to-wake strain projection was recomputed.
    /// This is deliberately independent of the latest live HR sample; a radio
    /// pause cannot invalidate load already accumulated from durable evidence.
    var strainCapturedAt: Date? = nil
    /// Physiological wake-to-wake cycle owning `strain`. Optional for backward
    /// decoding, but current widgets fail closed when either boundary is absent.
    var strainCycleStart: Date? = nil
    var strainCycleExpiresAt: Date? = nil
    let restingHR: Int?
    let hrvRMSSD: Int?
    let hrvState: String
    let maxHR: Int
    // Sleep duration for the Sleep h chip/column on Home Screen widgets. Optional
    // so widgets built against schema <4 payloads still decode (missing key -> nil).
    let sleepHours: Double?
    /// Display-only provenance. A reviewable duration may be shown here without
    /// authorizing that sleep for Recovery, debt, or physiological boundaries.
    var sleepDetail: String? = nil
    // Lock Screen single-metric widgets (Steps / BPM, alongside Strain / HRV).
    var steps: Int?
    /// `true` means a fresh strap-derived preliminary count. Widgets must
    /// prefix it with `~` and never present it as a validated exact total.
    var stepsAreEstimated: Bool? = nil
    /// Timestamp of the most recent CRC-valid strap motion frame supporting
    /// `steps`. Independent from `createdAt`, which can advance for battery,
    /// recovery, or layout changes without making the step stream fresh.
    var stepsCapturedAt: Date?
    /// Additive provenance fields keep schema-4 payloads backward decodable
    /// while letting widgets distinguish a live packet from durable canonical
    /// archive evidence.
    var stepsSource: String? = nil
    var stepsCompleteness: String? = nil
    var stepsCoverageFraction: Double? = nil
    /// Release authority carried into the extension process. Missing values
    /// belong to pre-qualification snapshots and must fail closed after an app
    /// update instead of keeping a disproven v15 subtotal visible.
    var stepsAuthorityVersion: String? = nil
    var stepsCycleStart: Date? = nil
    var stepsCycleExpiresAt: Date? = nil
    /// App-only monotonic authority for the durable receipt lane. These
    /// additive fields remain present even when an observed-motion receipt
    /// correctly withholds `steps`, allowing that newer unresolved receipt to
    /// invalidate a stale count without an older asynchronous patch restoring
    /// it afterward. The widget extension ignores unknown keys.
    var stepsReceiptAuthorityVersion: String? = nil
    var stepsReceiptSourceIdentifier: String? = nil
    var stepsReceiptCycleStart: Date? = nil
    var stepsReceiptCapturedAt: Date? = nil
    /// SHA-256 identity of the exact durable daily-receipt content. A receipt
    /// correction may legitimately retain `stepsReceiptCapturedAt`, so this
    /// additive key is the equal-clock ordering authority.
    var stepsReceiptContentRevision: String? = nil
    /// Receipt revision that directly owns the displayed step family. Nil
    /// means the displayed exact canonical row came from an independent full
    /// projection; receipt metadata may still advance beside it without
    /// gaining authority to replace that row.
    var stepsDisplayedReceiptContentRevision: String? = nil
    /// The latest receipt observed motion but could not resolve a gait count.
    /// It therefore invalidates an older partial projection without claiming
    /// that an exact zero was observed.
    var stepsReceiptInvalidatesIndependentPartial: Bool? = nil
    /// 2026-07-31: additive disclosure of the newest receipt that closed
    /// before the current wake boundary. Present only while `steps` is nil so
    /// a prior-cycle subtotal can be named in the detail line without ever
    /// masquerading as today's count.
    var stepsPriorCycleSteps: Int? = nil
    var stepsPriorCycleEndedAt: Date? = nil
    /// Optional so schema-4 snapshots written before goals were added still
    /// decode. This is the user's all-day strap-step goal, never a workout
    /// session delta.
    var dailyStepGoal: Int? = nil
    let heartRate: Int?
    /// Timestamp of the accepted strap HR sample supporting `heartRate`.
    let heartRateCapturedAt: Date?
    /// Canonical zone computed by the app's shared HRZone model. Keeping the
    /// result in the snapshot prevents the widget extension from reimplementing
    /// thresholds and drifting from the in-app workout UI.
    var heartRateZoneIndex: Int? = nil
    var heartRateZoneName: String? = nil
    let batteryLevel: Int?
    var batteryCapturedAt: Date? = nil
    /// A current 2A19 notification lease can corroborate an unchanged accepted
    /// mid-range level without pretending that a new battery packet arrived.
    var batteryCorroboratedAt: Date? = nil
    /// Independent evidence clock for charger state. A fresh percentage or
    /// notification lease must never renew an older charging/full claim.
    var batteryChargeCapturedAt: Date? = nil
    let batteryChargeStatus: String?
    let batteryChargeText: String?
    let layoutGlanceMetrics: [String]?
    let layoutRingCenterMetric: String?
    let layoutLegendStatStyle: String?
    let layoutAccent: String?
    let storage: String
    let appGroupEnabled: Bool
    let widgetTargetPresent: Bool
    let complicationTargetPresent: Bool
}

@MainActor
enum WidgetSnapshotPublisher {
    nonisolated static let qualifiedStepAuthorityVersion =
        "strap-steps-release-v1"

    struct Diagnostics {
        let storage: String
        let appGroupEnabled: Bool
        let widgetTargetPresent: Bool
        let complicationTargetPresent: Bool
    }

    /// The narrow, durable input consumed by the receipt-only widget lane.
    /// It deliberately contains no HR, Recovery, strain, battery, or layout
    /// values, so applying it to the latest shared snapshot cannot replace a
    /// fresher projection owned by another publisher.
    struct DurableStepProjection: Equatable {
        let authorityVersion: String
        let sourceIdentifier: String
        let cycleStart: Date
        let cycleExpiresAt: Date
        let receiptCapturedAt: Date?
        let receiptContentRevision: String?
        let displayedReceiptContentRevision: String?
        let receiptInvalidatesIndependentPartial: Bool
        let steps: Int?
        let stepsAreEstimated: Bool?
        let stepsCapturedAt: Date?
        let stepsSource: String?
        let stepsCompleteness: String?
        let stepsCoverageFraction: Double?
        let priorCycleSteps: Int?
        let priorCycleEndedAt: Date?
    }

    private static let key = "atria.widgetSnapshot.v1"
    private static let appGroupID = "group.com.adidshaft.atria"
    // Perf (docs/26 follow-up): bundle layout + entitlements are immutable for
    // the process lifetime, but `diagnostics` was recomputed on every widget
    // publish — a synchronous FileManager.contentsOfDirectory + bundle reads +
    // mobileprovision Data(contentsOf:) on the main thread. Compute once and
    // cache (MainActor-isolated, so the cache write is race-free).
    private static var cachedDiagnostics: Diagnostics?
    private static var scheduledPublishTask: Task<Void, Never>?
    /// Receipt saves must not compete with or be cancelled by the broader
    /// recovery/widget publisher. This lane reads the already-durable receipt
    /// and rewrites only step fields in the latest shared snapshot.
    private static var scheduledDurableStepPatchTask: Task<Void, Never>?
#if canImport(WidgetKit)
    /// WidgetKit is not a 1 Hz surface, but dropping every change below the old
    /// 100-step bucket made short walks invisible. Keep one independent,
    /// trailing delivery lane for sensor changes: writes remain immediate in
    /// the shared container, while visible timeline reloads are coalesced to a
    /// bounded cadence. The trailing task is important when a short walk ends
    /// before the cadence window opens -- its final count still reaches the
    /// widget without waiting for an unrelated dashboard update.
    private static var lastTimelineReloadSnapshot: WidgetSnapshot?
    private static var lastTimelineReloadDate: Date?
    private static var pendingTimelineReloadSnapshot: WidgetSnapshot?
    private static var pendingTimelineReloadTask: Task<Void, Never>?
    private static var pendingTimelineReloadDeadline: Date?
#endif

    /// During an active workout the stable daily fields (recovery, HRV, sleep,
    /// layout) do not need to be rebuilt from SessionStore for every pulse.
    /// Patch only the genuinely live values in the already-durable snapshot.
    /// This keeps Lock Screen widgets current without running recovery/cycle/
    /// rollup/TRIMP scans on the main actor during workout controls or a scene
    /// return animation.
    static func scheduleLiveWorkoutPatch(heartRate: Int?,
                                         heartRateCapturedAt: Date?,
                                         steps: Int?,
                                         stepsAreEstimated: Bool,
                                         stepsCapturedAt: Date?,
                                         stepsSource: String? = nil,
                                         stepsCompleteness: String? = nil,
                                         stepsCoverageFraction: Double? = nil,
                                         stepsAuthorityVersion: String? = nil,
                                         strain: Double,
                                         strainDetail: String? = nil,
                                         strainCapturedAt: Date? = nil,
                                         batteryLevel: Int?,
                                         batteryCapturedAt: Date? = nil,
                                         batteryCorroboratedAt: Date? = nil,
                                         batteryChargeCapturedAt: Date? = nil,
                                         batteryChargeStatus: String,
                                         batteryChargeText: String,
                                         reason: String,
                                         delay: Duration = .milliseconds(60)) {
        scheduledPublishTask?.cancel()
        scheduledPublishTask = Task { @MainActor in
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let widgetDiagnostics = diagnostics
            let defaults = widgetDiagnostics.appGroupEnabled
                ? (UserDefaults(suiteName: appGroupID) ?? .standard)
                : .standard
            guard let data = defaults.data(forKey: key),
                  let current = try? JSONDecoder.widgetSnapshotDecoder.decode(
                    WidgetSnapshot.self,
                    from: data
                  ) else {
                scheduledPublishTask = nil
                return
            }
            let patched = liveWorkoutPatchedSnapshot(
                current: current,
                createdAt: Date(),
                heartRate: heartRate,
                heartRateCapturedAt: heartRateCapturedAt,
                steps: steps,
                stepsAreEstimated: stepsAreEstimated,
                stepsCapturedAt: stepsCapturedAt,
                stepsSource: stepsSource,
                stepsCompleteness: stepsCompleteness,
                stepsCoverageFraction: stepsCoverageFraction,
                stepsAuthorityVersion: stepsAuthorityVersion,
                strain: strain,
                strainDetail: strainDetail,
                strainCapturedAt: strainCapturedAt,
                batteryLevel: batteryLevel,
                batteryCapturedAt: batteryCapturedAt,
                batteryCorroboratedAt: batteryCorroboratedAt,
                batteryChargeCapturedAt: batteryChargeCapturedAt,
                batteryChargeStatus: batteryChargeStatus,
                batteryChargeText: batteryChargeText
            )
            guard let patchedData = try? JSONEncoder.widgetSnapshotEncoder.encode(patched) else {
                scheduledPublishTask = nil
                return
            }
            defaults.set(patchedData, forKey: key)
            #if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled {
                scheduleTimelineReload(for: patched)
            }
            #endif
            AtriaDebugLog("ATRIADBG widget_snapshot status=live_workout_patch reason=%@ bytes=%d",
                          reason,
                          patchedData.count)
            scheduledPublishTask = nil
        }
    }

    /// A daily receipt is already fsync'd before `didSaveNotification` is
    /// posted. Publish that one authority without waiting for the broad
    /// Recovery/card readiness fence and without rebuilding unrelated fields.
    static func scheduleDurableStepPatch(
        store: SessionStore,
        reason: String,
        delay: Duration = .milliseconds(20)
    ) {
        scheduledDurableStepPatchTask?.cancel()
        scheduledDurableStepPatchTask = Task { @MainActor in
            await Task.yield()
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }

            let now = Date()
            guard let sourceIdentifier =
                    AtriaWhoop4MotionTickDailyStore
                        .persistedStrapIdentifiers().first,
                  let projection = durableStepProjection(
                    store: store,
                    sourceIdentifier: sourceIdentifier,
                    now: now
                  ) else {
                AtriaDebugLog(
                    "ATRIADBG widget_snapshot status=durable_steps_skipped reason=%@ detail=missing_qualified_source",
                    reason
                )
                return
            }
            let widgetDiagnostics = diagnostics
            let defaults = widgetDiagnostics.appGroupEnabled
                ? (UserDefaults(suiteName: appGroupID) ?? .standard)
                : .standard
            guard let data = defaults.data(forKey: key),
                  let current = try? JSONDecoder.widgetSnapshotDecoder.decode(
                    WidgetSnapshot.self,
                    from: data
                  ) else {
                // A step-only patch cannot honestly synthesize Recovery, HR,
                // or layout fields. The first full eligible publication will
                // carry the same durable receipt metadata.
                AtriaDebugLog(
                    "ATRIADBG widget_snapshot status=durable_steps_skipped reason=%@ detail=no_existing_snapshot",
                    reason
                )
                return
            }
            guard let patched = durableStepPatchedSnapshot(
                current: current,
                projection: projection,
                currentPersistedSourceIdentifier: sourceIdentifier,
                deliveredAt: now
            ),
                  let patchedData = try? JSONEncoder.widgetSnapshotEncoder
                    .encode(patched) else {
                AtriaDebugLog(
                    "ATRIADBG widget_snapshot status=durable_steps_skipped reason=%@ detail=stale_or_invalid_authority",
                    reason
                )
                return
            }
            defaults.set(patchedData, forKey: key)
            #if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled {
                scheduleTimelineReload(for: patched)
            }
            #endif
            AtriaDebugLog(
                "ATRIADBG widget_snapshot status=durable_steps_patch reason=%@ steps=%@ receipt_at=%.3f bytes=%d",
                reason,
                formatInt(patched.steps),
                projection.receiptCapturedAt?.timeIntervalSince1970 ?? -1,
                patchedData.count
            )
        }
    }

    private static func durableStepProjection(
        store: SessionStore,
        sourceIdentifier: String,
        now: Date,
        calendar: Calendar = .current
    ) -> DurableStepProjection? {
        guard AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified else { return nil }
        let cycle = AtriaPhysiologicalCycle.current(
            now: now,
            confirmedSleeps: store.confirmedSleeps,
            calendar: calendar
        )
        let publication = AtriaWhoop4MotionTickDailyStore.shared
            .currentCyclePublication(
                into: [],
                strapIdentifiers: [sourceIdentifier],
                windowStart: cycle.start,
                now: now,
                calendar: calendar
            )
        let receiptDays = publication.projectedDays
        let receiptCapturedAt = publication.receipt?.evidence.capturedThrough
        let priorReceipt = AtriaWhoop4MotionTickDailyStore.shared
            .latestReceipt(
                before: cycle.start,
                strapIdentifiers: [sourceIdentifier]
            )
        let presentation = resolvedDailySteps(
            day: now,
            now: now,
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: receiptDays,
            liveAuthorityQualified: true,
            physiologicalDayStart: cycle.start,
            priorCycleReceipt: priorReceipt.map {
                .init(steps: $0.steps, endedAt: $0.capturedThrough)
            },
            calendar: calendar
        )
        let publishedSteps = presentation.count
        let displayedReceiptContentRevision = publishedSteps != nil
            && presentation.capturedAt == receiptCapturedAt
            && publishedSteps == publication.receipt?.evidence.steps
            && stepSourceIdentifier(presentation.source)
                == "verifiedCanonical"
            ? publication.displayedReceiptContentRevision : nil
        return .init(
            authorityVersion: qualifiedStepAuthorityVersion,
            sourceIdentifier: sourceIdentifier,
            cycleStart: cycle.start,
            cycleExpiresAt: cumulativeStrainCycleExpiration(
                cycle: cycle,
                confirmedSleeps: store.confirmedSleeps,
                calendar: calendar
            ),
            receiptCapturedAt: receiptCapturedAt,
            receiptContentRevision:
                publication.receipt?.contentRevision,
            displayedReceiptContentRevision:
                displayedReceiptContentRevision,
            receiptInvalidatesIndependentPartial:
                publication.receiptInvalidatesIndependentPartial,
            steps: publishedSteps,
            stepsAreEstimated: publishedSteps == nil ? nil
                : (!presentation.isValidated
                    || presentation.completeness == .partial),
            stepsCapturedAt: presentation.capturedAt,
            stepsSource: stepSourceIdentifier(presentation.source),
            stepsCompleteness:
                stepCompletenessIdentifier(presentation.completeness),
            stepsCoverageFraction: presentation.coverageFraction,
            priorCycleSteps: presentation.priorCycleReceipt?.steps,
            priorCycleEndedAt: presentation.priorCycleReceipt?.endedAt
        )
    }

    /// Applies only a current persisted strap's monotonic receipt authority.
    /// A newer cycle (including an empty rollover) or replacement strap may
    /// invalidate old steps. Within the same source/cycle, a missing or older
    /// receipt can never clear a value supported by fresher live/durable data.
    nonisolated static func durableStepPatchedSnapshot(
        current: WidgetSnapshot,
        projection: DurableStepProjection,
        currentPersistedSourceIdentifier: String,
        deliveredAt: Date
    ) -> WidgetSnapshot? {
        let incomingReceiptRevision = canonicalStepReceiptContentRevision(
            projection.receiptContentRevision
        )
        let incomingDisplayedReceiptRevision =
            canonicalStepReceiptContentRevision(
                projection.displayedReceiptContentRevision
            )
        guard AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified,
              projection.authorityVersion == qualifiedStepAuthorityVersion,
              let incomingSource = canonicalStepReceiptSourceIdentifier(
                projection.sourceIdentifier
              ),
              incomingSource == canonicalStepReceiptSourceIdentifier(
                currentPersistedSourceIdentifier
              ),
              projection.cycleStart <= deliveredAt.addingTimeInterval(5),
              projection.cycleExpiresAt > projection.cycleStart,
              projection.receiptCapturedAt.map({
                $0 >= projection.cycleStart.addingTimeInterval(-1)
                    && $0 <= deliveredAt.addingTimeInterval(5)
              }) ?? true,
              projection.receiptCapturedAt == nil
                ? projection.receiptContentRevision == nil
                : incomingReceiptRevision != nil,
              projection.displayedReceiptContentRevision == nil
                || (incomingDisplayedReceiptRevision
                        == incomingReceiptRevision
                    && projection.steps != nil),
              !projection.receiptInvalidatesIndependentPartial
                || (projection.steps == nil
                    && incomingDisplayedReceiptRevision == nil) else {
            return nil
        }

        let previousReceiptAuthorityQualified =
            current.stepsReceiptAuthorityVersion
                == qualifiedStepAuthorityVersion
        let previousSource = previousReceiptAuthorityQualified
            ? canonicalStepReceiptSourceIdentifier(
                current.stepsReceiptSourceIdentifier
            )
            : nil
        let isReplacementSource = previousSource.map {
            $0 != incomingSource
        } ?? false
        let previousCycle = (previousReceiptAuthorityQualified
            ? current.stepsReceiptCycleStart : nil)
            ?? current.stepsCycleStart
        let cycleDelta = previousCycle.map {
            projection.cycleStart.timeIntervalSince($0)
        }
        let isSameCycle = cycleDelta.map { abs($0) < 1 } ?? false
        let currentDisplayedReceiptRevision =
            canonicalStepReceiptContentRevision(
                current.stepsDisplayedReceiptContentRevision
            )
        let currentIsIndependentPartial = current.steps != nil
            && current.stepsSource == "verifiedCanonical"
            && current.stepsCompleteness == "partial"
            && current.stepsAuthorityVersion == qualifiedStepAuthorityVersion
            && currentDisplayedReceiptRevision == nil
        let incomingCompletenessRank: Int
        switch projection.stepsCompleteness {
        case "complete": incomingCompletenessRank = 2
        case "partial": incomingCompletenessRank = 1
        default: incomingCompletenessRank = 0
        }
        let currentCompletenessRank = current.stepsCompleteness == "complete"
            ? 2 : (current.stepsCompleteness == "partial" ? 1 : 0)
        let incomingCoverage = projection.stepsCoverageFraction ?? 0
        let currentCoverage = current.stepsCoverageFraction ?? 0
        let incomingOutranksIndependentPartialWithoutClock =
            projection.receiptInvalidatesIndependentPartial
            || incomingCompletenessRank > currentCompletenessRank
            || (incomingCompletenessRank == currentCompletenessRank
                && incomingCoverage > currentCoverage)

        if !isReplacementSource {
            if let cycleDelta, cycleDelta < -1 { return nil }
            if isSameCycle {
                guard let incomingReceiptAt = projection.receiptCapturedAt
                else { return nil }
                let previousEvidenceAt = [
                    previousReceiptAuthorityQualified
                        ? current.stepsReceiptCapturedAt : nil,
                    current.stepsCapturedAt,
                ].compactMap { $0 }.max()
                if let previousEvidenceAt,
                   incomingReceiptAt < previousEvidenceAt,
                   !(currentIsIndependentPartial
                        && incomingOutranksIndependentPartialWithoutClock) {
                    return nil
                }
            } else if previousCycle == nil,
                      projection.receiptCapturedAt == nil {
                // A legacy snapshot with no cycle/source authority cannot be
                // cleared merely because an unrelated no-op notification ran.
                return nil
            }
        }

        // A publishable receipt must carry the same qualified product
        // provenance used by every other step surface. An unresolved receipt
        // intentionally carries no displayed value fields.
        if projection.steps != nil {
            guard projection.stepsCapturedAt != nil,
                  projection.stepsCapturedAt == projection.receiptCapturedAt,
                  projection.stepsSource == "verifiedCanonical"
            else { return nil }
        }

        var patched = current
        patched.createdAt = max(current.createdAt, deliveredAt)
        patched.stepsReceiptAuthorityVersion = projection.authorityVersion
        patched.stepsReceiptSourceIdentifier = incomingSource
        patched.stepsReceiptCycleStart = projection.cycleStart
        patched.stepsReceiptCapturedAt = projection.receiptCapturedAt
        patched.stepsReceiptContentRevision = incomingReceiptRevision
        patched.stepsReceiptInvalidatesIndependentPartial =
            projection.receiptInvalidatesIndependentPartial
        let incomingSupersedesReceiptOwnedExact =
            currentDisplayedReceiptRevision != nil
            && incomingReceiptRevision != currentDisplayedReceiptRevision
        let incomingDisplayedAt = projection.stepsCapturedAt
            ?? projection.receiptCapturedAt
        let incomingIsStrongerThanIndependentPartial: Bool
        if projection.receiptInvalidatesIndependentPartial {
            incomingIsStrongerThanIndependentPartial = true
        } else if incomingCompletenessRank != currentCompletenessRank {
            incomingIsStrongerThanIndependentPartial =
                incomingCompletenessRank > currentCompletenessRank
        } else if incomingCoverage != currentCoverage {
            // Coverage has the same cycle denominator and is the durable
            // store's primary partial-strength authority. A later clock alone
            // cannot make a sparser subtotal stronger.
            incomingIsStrongerThanIndependentPartial =
                incomingCoverage > currentCoverage
        } else {
            incomingIsStrongerThanIndependentPartial =
                incomingDisplayedAt.map { incomingAt in
                    current.stepsCapturedAt.map { incomingAt > $0 } ?? true
                } ?? false
        }
        let preservesIndependentPartial = previousReceiptAuthorityQualified
            && previousSource == incomingSource
            && isSameCycle
            && currentIsIndependentPartial
            && !incomingIsStrongerThanIndependentPartial
        let preservesExactCanonical = previousReceiptAuthorityQualified
            && previousSource == incomingSource
            && isSameCycle
            && current.steps != nil
            && current.stepsSource == "verifiedCanonical"
            && current.stepsCompleteness == "complete"
            && current.stepsAuthorityVersion == qualifiedStepAuthorityVersion
            && !incomingSupersedesReceiptOwnedExact
        if preservesExactCanonical || preservesIndependentPartial {
            // `durableStepProjection` intentionally avoids the asynchronous
            // history snapshot. An independently projected exact row outranks
            // a receipt, and an equal-clock independent partial row keeps the
            // stronger completeness/coverage. A row owned by an old receipt
            // must follow any new receipt revision, including clearing when
            // the new receipt is unresolved.
            return patched
        }
        patched.steps = projection.steps
        patched.stepsAreEstimated = projection.steps == nil
            ? nil : projection.stepsAreEstimated
        patched.stepsCapturedAt = projection.steps == nil
            ? nil : projection.stepsCapturedAt
        patched.stepsSource = projection.steps == nil
            ? nil : projection.stepsSource
        patched.stepsCompleteness = projection.steps == nil
            ? nil : projection.stepsCompleteness
        patched.stepsCoverageFraction = projection.steps == nil
            ? nil : projection.stepsCoverageFraction
        patched.stepsAuthorityVersion = projection.steps == nil
            ? nil : projection.authorityVersion
        patched.stepsCycleStart = projection.steps == nil
            ? nil : projection.cycleStart
        patched.stepsCycleExpiresAt = projection.steps == nil
            ? nil : projection.cycleExpiresAt
        patched.stepsDisplayedReceiptContentRevision = projection.steps == nil
            ? nil : incomingDisplayedReceiptRevision
        patched.stepsPriorCycleSteps = projection.steps == nil
            ? projection.priorCycleSteps : nil
        patched.stepsPriorCycleEndedAt = projection.steps == nil
            ? projection.priorCycleEndedAt : nil
        return patched
    }

    nonisolated private static func canonicalStepReceiptSourceIdentifier(
        _ value: String?
    ) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString
    }

    nonisolated private static func canonicalStepReceiptContentRevision(
        _ value: String?
    ) -> String? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            return nil
        }
        return value
    }

    /// A broad rebuild can start immediately before a background receipt save
    /// and reach UserDefaults after the receipt-only lane. Merge only the step
    /// family from the stronger already-delivered authority; every non-step
    /// field remains owned by the new broad candidate.
    nonisolated static func snapshotPreservingFresherStepAuthority(
        candidate: WidgetSnapshot,
        current: WidgetSnapshot,
        authoritativeReceiptContentRevision: String? = nil
    ) -> WidgetSnapshot {
        guard AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified else {
            // Gate-4 revocation must clear every former product projection;
            // monotonic delivery metadata cannot keep a disproven count alive.
            return candidate
        }
        let candidateReceiptAuthorityQualified =
            candidate.stepsReceiptAuthorityVersion
                == qualifiedStepAuthorityVersion
        let currentReceiptAuthorityQualified =
            current.stepsReceiptAuthorityVersion
                == qualifiedStepAuthorityVersion
        let candidateSource = candidateReceiptAuthorityQualified
            ? canonicalStepReceiptSourceIdentifier(
                candidate.stepsReceiptSourceIdentifier
            )
            : nil
        let currentSource = currentReceiptAuthorityQualified
            ? canonicalStepReceiptSourceIdentifier(
                current.stepsReceiptSourceIdentifier
            )
            : nil
        let shouldPreserveCurrent: Bool
        if let candidateSource, let currentSource,
           candidateSource != currentSource {
            // A full publish resolves the currently persisted strap identity;
            // never import a former strap's projection into that candidate.
            shouldPreserveCurrent = false
        } else if candidateSource != nil, currentSource == nil {
            shouldPreserveCurrent = false
        } else if candidateSource == nil, currentSource != nil {
            // Losing the persisted identity is also an authority change. Do
            // not keep a former strap's count alive under an anonymous source.
            shouldPreserveCurrent = false
        } else {
            let candidateCycle = (candidateReceiptAuthorityQualified
                ? candidate.stepsReceiptCycleStart : nil)
                ?? candidate.stepsCycleStart
            let currentCycle = (currentReceiptAuthorityQualified
                ? current.stepsReceiptCycleStart : nil)
                ?? current.stepsCycleStart
            if let candidateCycle, let currentCycle,
               abs(candidateCycle.timeIntervalSince(currentCycle)) >= 1 {
                shouldPreserveCurrent = currentCycle > candidateCycle
            } else if candidateCycle == nil, currentCycle != nil {
                shouldPreserveCurrent = true
            } else if candidateCycle != nil, currentCycle == nil {
                shouldPreserveCurrent = false
            } else {
                let candidateHasIndependentExactCanonicalSteps =
                    candidate.steps != nil
                    && candidate.stepsSource == "verifiedCanonical"
                    && candidate.stepsCompleteness == "complete"
                    && candidate.stepsAuthorityVersion
                        == qualifiedStepAuthorityVersion
                    && candidate.stepsDisplayedReceiptContentRevision == nil
                let currentHasIndependentExactCanonicalSteps =
                    current.steps != nil
                    && current.stepsSource == "verifiedCanonical"
                    && current.stepsCompleteness == "complete"
                    && current.stepsAuthorityVersion
                        == qualifiedStepAuthorityVersion
                    && current.stepsDisplayedReceiptContentRevision == nil
                if candidateHasIndependentExactCanonicalSteps
                    && currentHasIndependentExactCanonicalSteps {
                    // Receipt clocks own neither independent row. Order their
                    // displayed evidence directly: a newer delivered exact row
                    // cannot regress, while equal clocks choose the freshly
                    // computed broad candidate.
                    shouldPreserveCurrent = current.stepsCapturedAt.map {
                        currentAt in
                        candidate.stepsCapturedAt.map {
                            currentAt > $0
                        } ?? true
                    } ?? false
                } else if candidateHasIndependentExactCanonicalSteps
                    || currentHasIndependentExactCanonicalSteps {
                    // An independent full canonical row outranks a receipt-
                    // owned row even if a newer receipt lands while the broad
                    // candidate is being built. The later receipt patch can
                    // update receipt metadata, but cannot recreate a broad
                    // row that this merge discards.
                    shouldPreserveCurrent =
                        currentHasIndependentExactCanonicalSteps
                } else {
                    let candidateHasIndependentPartialCanonicalSteps =
                        candidate.steps != nil
                        && candidate.stepsSource == "verifiedCanonical"
                        && candidate.stepsCompleteness == "partial"
                        && candidate.stepsAuthorityVersion
                            == qualifiedStepAuthorityVersion
                        && candidate.stepsDisplayedReceiptContentRevision == nil
                    let currentHasIndependentPartialCanonicalSteps =
                        current.steps != nil
                        && current.stepsSource == "verifiedCanonical"
                        && current.stepsCompleteness == "partial"
                        && current.stepsAuthorityVersion
                            == qualifiedStepAuthorityVersion
                        && current.stepsDisplayedReceiptContentRevision == nil
                    let candidateInvalidatesIndependentPartial =
                        candidate.stepsReceiptInvalidatesIndependentPartial
                            == true
                    let currentInvalidatesIndependentPartial =
                        current.stepsReceiptInvalidatesIndependentPartial
                            == true
                    if candidateInvalidatesIndependentPartial
                        && currentHasIndependentPartialCanonicalSteps {
                        // Observed motion with no qualified gait subtotal is
                        // explicit negative authority for an older partial.
                        // It never invalidates an independently projected
                        // complete row (handled above).
                        shouldPreserveCurrent = false
                    } else if currentInvalidatesIndependentPartial
                                && candidateHasIndependentPartialCanonicalSteps {
                        shouldPreserveCurrent = true
                    } else if candidateHasIndependentPartialCanonicalSteps
                                || currentHasIndependentPartialCanonicalSteps {
                        // Receipt clocks do not own an independent partial.
                        // Mirror the daily-store merge: completeness and
                        // coverage outrank time, then compare the displayed
                        // evidence clock. On an exact tie the fresh broad
                        // candidate wins unless only the current row is
                        // independent.
                        let candidateCompletenessRank =
                            candidate.stepsCompleteness == "complete" ? 2
                            : (candidate.stepsCompleteness == "partial" ? 1 : 0)
                        let currentCompletenessRank =
                            current.stepsCompleteness == "complete" ? 2
                            : (current.stepsCompleteness == "partial" ? 1 : 0)
                        if candidateCompletenessRank
                            != currentCompletenessRank {
                            shouldPreserveCurrent = currentCompletenessRank
                                > candidateCompletenessRank
                        } else {
                            let candidateCoverage =
                                candidate.stepsCoverageFraction ?? 0
                            let currentCoverage =
                                current.stepsCoverageFraction ?? 0
                            if candidateCoverage != currentCoverage {
                                shouldPreserveCurrent = currentCoverage
                                    > candidateCoverage
                            } else if candidate.stepsCapturedAt
                                        != current.stepsCapturedAt {
                                shouldPreserveCurrent =
                                    current.stepsCapturedAt.map { currentAt in
                                        candidate.stepsCapturedAt.map {
                                            currentAt > $0
                                        } ?? true
                                    } ?? false
                            } else {
                                shouldPreserveCurrent =
                                    currentHasIndependentPartialCanonicalSteps
                                    && !candidateHasIndependentPartialCanonicalSteps
                            }
                        }
                    } else {
                        let candidateEvidenceAt = [
                            candidateReceiptAuthorityQualified
                                ? candidate.stepsReceiptCapturedAt : nil,
                            candidate.stepsCapturedAt,
                        ].compactMap { $0 }.max()
                        let currentEvidenceAt = [
                            currentReceiptAuthorityQualified
                                ? current.stepsReceiptCapturedAt : nil,
                            current.stepsCapturedAt,
                        ].compactMap { $0 }.max()
                        if let candidateEvidenceAt, let currentEvidenceAt,
                           candidateEvidenceAt == currentEvidenceAt {
                            let candidateRevision =
                                candidateReceiptAuthorityQualified
                                ? canonicalStepReceiptContentRevision(
                                    candidate.stepsReceiptContentRevision
                                ) : nil
                            let currentRevision =
                                currentReceiptAuthorityQualified
                                ? canonicalStepReceiptContentRevision(
                                    current.stepsReceiptContentRevision
                                ) : nil
                            let authoritativeRevision =
                                canonicalStepReceiptContentRevision(
                                    authoritativeReceiptContentRevision
                                )
                            if let authoritativeRevision {
                                if authoritativeRevision == currentRevision {
                                    shouldPreserveCurrent =
                                        authoritativeRevision
                                        != candidateRevision
                                } else if authoritativeRevision
                                            == candidateRevision {
                                    shouldPreserveCurrent = false
                                } else {
                                    // Neither asynchronous snapshot represents
                                    // the current durable content. Retain the
                                    // already-delivered step family until its
                                    // receipt patch lands; unrelated full fields
                                    // may still advance.
                                    shouldPreserveCurrent = true
                                }
                            } else if candidateRevision == currentRevision {
                                shouldPreserveCurrent = false
                            } else {
                                // With two different same-clock records and no
                                // durable tie-break proof, overwriting the
                                // delivered value would be unprovable.
                                shouldPreserveCurrent = true
                            }
                        } else {
                            shouldPreserveCurrent = currentEvidenceAt.map {
                                currentAt in
                                candidateEvidenceAt.map {
                                    currentAt > $0
                                } ?? true
                            } ?? false
                        }
                    }
                }
            }
        }
        guard shouldPreserveCurrent else { return candidate }

        var merged = candidate
        merged.steps = current.steps
        merged.stepsAreEstimated = current.stepsAreEstimated
        merged.stepsCapturedAt = current.stepsCapturedAt
        merged.stepsSource = current.stepsSource
        merged.stepsCompleteness = current.stepsCompleteness
        merged.stepsCoverageFraction = current.stepsCoverageFraction
        merged.stepsAuthorityVersion = current.stepsAuthorityVersion
        merged.stepsCycleStart = current.stepsCycleStart
        merged.stepsCycleExpiresAt = current.stepsCycleExpiresAt
        merged.stepsReceiptAuthorityVersion =
            current.stepsReceiptAuthorityVersion
        merged.stepsReceiptSourceIdentifier =
            current.stepsReceiptSourceIdentifier
        merged.stepsReceiptCycleStart = current.stepsReceiptCycleStart
        merged.stepsReceiptCapturedAt = current.stepsReceiptCapturedAt
        merged.stepsReceiptContentRevision =
            current.stepsReceiptContentRevision
        merged.stepsDisplayedReceiptContentRevision =
            current.stepsDisplayedReceiptContentRevision
        merged.stepsReceiptInvalidatesIndependentPartial =
            current.stepsReceiptInvalidatesIndependentPartial
        merged.stepsPriorCycleSteps = current.stepsPriorCycleSteps
        merged.stepsPriorCycleEndedAt = current.stepsPriorCycleEndedAt
        return merged
    }

    nonisolated static func liveWorkoutPatchedSnapshot(
        current: WidgetSnapshot,
        createdAt: Date,
        heartRate: Int?,
        heartRateCapturedAt: Date?,
        steps: Int?,
        stepsAreEstimated: Bool,
        stepsCapturedAt: Date?,
        stepsSource: String? = nil,
        stepsCompleteness: String? = nil,
        stepsCoverageFraction: Double? = nil,
        stepsAuthorityVersion: String? = nil,
        strain: Double,
        strainDetail: String? = nil,
        strainCapturedAt: Date? = nil,
        batteryLevel: Int?,
        batteryCapturedAt: Date? = nil,
        batteryCorroboratedAt: Date? = nil,
        batteryChargeCapturedAt: Date? = nil,
        batteryChargeStatus: String,
        batteryChargeText: String
    ) -> WidgetSnapshot {
        let heartRateZone = heartRate.map {
            HRZone.zone(for: $0, maxHR: current.maxHR, restingHR: current.restingHR)
        }
        let incomingStepEvidenceAt = steps.flatMap { _ in stepsCapturedAt }
        let currentStepEvidenceAt = [
            current.stepsReceiptCapturedAt,
            current.stepsCapturedAt,
        ].compactMap { $0 }.max()
        // This lane may have captured its arguments before a durable receipt
        // landed. Keep the latest snapshot's step projection unless the live
        // sample is at least as new as every delivered step/receipt clock.
        let acceptsIncomingSteps = incomingStepEvidenceAt.map { incoming in
            let equalsRevisionedDurableReceipt =
                current.stepsReceiptAuthorityVersion
                    == qualifiedStepAuthorityVersion
                && canonicalStepReceiptContentRevision(
                    current.stepsReceiptContentRevision
                ) != nil
                && current.stepsReceiptCapturedAt == incoming
            return !equalsRevisionedDurableReceipt
                && (currentStepEvidenceAt.map { incoming >= $0 } ?? true)
        } ?? (current.steps == nil
                && current.stepsCapturedAt == nil
                && current.stepsReceiptCapturedAt == nil)
        let patchedSteps = acceptsIncomingSteps ? steps : current.steps
        let patchedStepsAreEstimated = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsAreEstimated)
            : current.stepsAreEstimated
        let patchedStepsCapturedAt = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsCapturedAt)
            : current.stepsCapturedAt
        let patchedStepsSource = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsSource)
            : current.stepsSource
        let patchedStepsCompleteness = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsCompleteness)
            : current.stepsCompleteness
        let patchedStepsCoverageFraction = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsCoverageFraction)
            : current.stepsCoverageFraction
        let patchedStepsAuthorityVersion = acceptsIncomingSteps
            ? (steps == nil ? nil : stepsAuthorityVersion)
            : current.stepsAuthorityVersion
        return WidgetSnapshot(
            schema: current.schema,
            createdAt: max(current.createdAt, createdAt),
            recoveryPercent: current.recoveryPercent,
            recoveryConfidence: current.recoveryConfidence,
            recoveryDetail: current.recoveryDetail,
            strain: strain,
            // A live patch may update the numeric lower bound, but it cannot
            // upgrade the evidence authority established by the full daily
            // projection. Preserve an existing partial marker unless the
            // caller explicitly supplies an equally conservative detail.
            strainDetail: mergedLiveStrainDetail(
                previous: current.strainDetail,
                next: strainDetail
            ),
            strainCapturedAt: cumulativeStrainCaptureDate(
                previousValue: current.strain,
                previousCapturedAt: current.strainCapturedAt,
                nextValue: strain,
                nextEvidenceAt: strainCapturedAt
            ),
            strainCycleStart: current.strainCycleStart,
            strainCycleExpiresAt: current.strainCycleExpiresAt,
            restingHR: current.restingHR,
            hrvRMSSD: current.hrvRMSSD,
            hrvState: current.hrvState,
            maxHR: current.maxHR,
            sleepHours: current.sleepHours,
            sleepDetail: current.sleepDetail,
            steps: patchedSteps,
            stepsAreEstimated: patchedStepsAreEstimated,
            stepsCapturedAt: patchedStepsCapturedAt,
            stepsSource: patchedStepsSource,
            stepsCompleteness: patchedStepsCompleteness,
            stepsCoverageFraction: patchedStepsCoverageFraction,
            stepsAuthorityVersion: patchedStepsAuthorityVersion,
            stepsCycleStart: acceptsIncomingSteps
                ? (steps == nil ? nil : current.stepsCycleStart)
                : current.stepsCycleStart,
            stepsCycleExpiresAt: acceptsIncomingSteps
                ? (steps == nil ? nil : current.stepsCycleExpiresAt)
                : current.stepsCycleExpiresAt,
            stepsReceiptAuthorityVersion:
                current.stepsReceiptAuthorityVersion,
            stepsReceiptSourceIdentifier:
                current.stepsReceiptSourceIdentifier,
            stepsReceiptCycleStart: current.stepsReceiptCycleStart,
            stepsReceiptCapturedAt: current.stepsReceiptCapturedAt,
            stepsReceiptContentRevision:
                current.stepsReceiptContentRevision,
            stepsDisplayedReceiptContentRevision: acceptsIncomingSteps
                ? nil : current.stepsDisplayedReceiptContentRevision,
            stepsReceiptInvalidatesIndependentPartial:
                current.stepsReceiptInvalidatesIndependentPartial,
            // Prior-cycle disclosure only exists while today's value is nil;
            // a live patch that publishes a current count clears it.
            stepsPriorCycleSteps: patchedSteps == nil
                ? current.stepsPriorCycleSteps : nil,
            stepsPriorCycleEndedAt: patchedSteps == nil
                ? current.stepsPriorCycleEndedAt : nil,
            dailyStepGoal: current.dailyStepGoal,
            heartRate: heartRate,
            heartRateCapturedAt: heartRate == nil ? nil : heartRateCapturedAt,
            heartRateZoneIndex: heartRate == nil ? nil : heartRateZone?.rawValue,
            heartRateZoneName: heartRate == nil ? nil : heartRateZone?.name,
            batteryLevel: batteryLevel,
            batteryCapturedAt: batteryLevel == nil ? nil : batteryCapturedAt,
            batteryCorroboratedAt: batteryLevel == nil ? nil : batteryCorroboratedAt,
            batteryChargeCapturedAt: batteryLevel == nil ? nil : batteryChargeCapturedAt,
            batteryChargeStatus: batteryChargeStatus,
            batteryChargeText: batteryChargeText,
            layoutGlanceMetrics: current.layoutGlanceMetrics,
            layoutRingCenterMetric: current.layoutRingCenterMetric,
            layoutLegendStatStyle: current.layoutLegendStatStyle,
            layoutAccent: current.layoutAccent,
            storage: current.storage,
            appGroupEnabled: current.appGroupEnabled,
            widgetTargetPresent: current.widgetTargetPresent,
            complicationTargetPresent: current.complicationTargetPresent
        )
    }

    /// A pulse-time patch may make an already-qualified cumulative value more
    /// current, but it cannot prove that missing all-day HR coverage appeared.
    /// Only a full projection rebuild owns that upgrade.
    nonisolated static func mergedLiveStrainDetail(
        previous: String?,
        next: String?
    ) -> String? {
        let previousIsPartial =
            previous?.localizedCaseInsensitiveContains("partial") == true
        let nextIsPartial =
            next?.localizedCaseInsensitiveContains("partial") == true
        if previousIsPartial, !nextIsPartial {
            return previous
        }
        return next ?? previous
    }

    /// Coalesces publisher bursts and lets scene/UI transitions commit before
    /// recovery, strain, JSON encoding, defaults writes, and WidgetKit reloads
    /// run on the main actor. Callers that require an immediate return value
    /// (proof/debug surfaces and bounded BG tasks) continue using `publish`.
    static func schedulePublish(store: SessionStore,
                                ble: AtriaBLEManager,
                                reason: String,
                                delay: Duration = .milliseconds(60)) {
        scheduledPublishTask?.cancel()
        scheduledPublishTask = Task { @MainActor in
            await Task.yield()
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            _ = publish(store: store, ble: ble, reason: reason)
            scheduledPublishTask = nil
        }
    }

    /// Clears only disputed battery fields immediately, even before deferred
    /// session loading permits a full snapshot rewrite.
    static func invalidateBatteryProjection(defaults injectedDefaults: UserDefaults? = nil) {
        let widgetDiagnostics = Self.diagnostics
        let defaults = injectedDefaults ?? (widgetDiagnostics.appGroupEnabled
            ? (UserDefaults(suiteName: appGroupID) ?? .standard)
            : .standard)
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder.widgetSnapshotDecoder.decode(WidgetSnapshot.self, from: data) else { return }
        let sanitized = WidgetSnapshot(schema: snapshot.schema,
                                       createdAt: Date(),
                                       recoveryPercent: snapshot.recoveryPercent,
                                       recoveryConfidence: snapshot.recoveryConfidence,
                                       recoveryDetail: snapshot.recoveryDetail,
                                       strain: snapshot.strain,
                                       strainDetail: snapshot.strainDetail,
                                       strainCapturedAt: snapshot.strainCapturedAt,
                                       strainCycleStart: snapshot.strainCycleStart,
                                       strainCycleExpiresAt: snapshot.strainCycleExpiresAt,
                                       restingHR: snapshot.restingHR,
                                       hrvRMSSD: snapshot.hrvRMSSD,
                                       hrvState: snapshot.hrvState,
                                       maxHR: snapshot.maxHR,
                                       sleepHours: snapshot.sleepHours,
                                       sleepDetail: snapshot.sleepDetail,
                                       steps: snapshot.steps,
                                       stepsAreEstimated: snapshot.stepsAreEstimated,
                                       stepsCapturedAt: snapshot.stepsCapturedAt,
                                       stepsSource: snapshot.stepsSource,
                                       stepsCompleteness: snapshot.stepsCompleteness,
                                       stepsCoverageFraction: snapshot.stepsCoverageFraction,
                                       stepsAuthorityVersion:
                                        snapshot.stepsAuthorityVersion,
                                       stepsCycleStart: snapshot.stepsCycleStart,
                                       stepsCycleExpiresAt: snapshot.stepsCycleExpiresAt,
                                       stepsReceiptAuthorityVersion:
                                        snapshot.stepsReceiptAuthorityVersion,
                                       stepsReceiptSourceIdentifier:
                                        snapshot.stepsReceiptSourceIdentifier,
                                       stepsReceiptCycleStart:
                                        snapshot.stepsReceiptCycleStart,
                                       stepsReceiptCapturedAt:
                                        snapshot.stepsReceiptCapturedAt,
                                       stepsReceiptContentRevision:
                                        snapshot.stepsReceiptContentRevision,
                                       stepsDisplayedReceiptContentRevision:
                                        snapshot.stepsDisplayedReceiptContentRevision,
                                       stepsReceiptInvalidatesIndependentPartial:
                                        snapshot.stepsReceiptInvalidatesIndependentPartial,
                                       stepsPriorCycleSteps: snapshot.stepsPriorCycleSteps,
                                       stepsPriorCycleEndedAt: snapshot.stepsPriorCycleEndedAt,
                                       dailyStepGoal: snapshot.dailyStepGoal,
                                       heartRate: snapshot.heartRate,
                                       heartRateCapturedAt: snapshot.heartRateCapturedAt,
                                       heartRateZoneIndex: snapshot.heartRateZoneIndex,
                                       heartRateZoneName: snapshot.heartRateZoneName,
                                       batteryLevel: nil,
                                       batteryCapturedAt: nil,
                                       batteryCorroboratedAt: nil,
                                       batteryChargeCapturedAt: nil,
                                       batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus.levelOnly.rawValue,
                                       batteryChargeText: "Unavailable",
                                       layoutGlanceMetrics: snapshot.layoutGlanceMetrics,
                                       layoutRingCenterMetric: snapshot.layoutRingCenterMetric,
                                       layoutLegendStatStyle: snapshot.layoutLegendStatStyle,
                                       layoutAccent: snapshot.layoutAccent,
                                       storage: snapshot.storage,
                                       appGroupEnabled: snapshot.appGroupEnabled,
                                       widgetTargetPresent: snapshot.widgetTargetPresent,
                                       complicationTargetPresent: snapshot.complicationTargetPresent)
        guard let sanitizedData = try? JSONEncoder.widgetSnapshotEncoder.encode(sanitized) else { return }
        defaults.set(sanitizedData, forKey: key)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        AtriaDebugLog("ATRIADBG widget_snapshot status=battery_invalidated reason=disputed_transition")
    }
    static var diagnostics: Diagnostics {
        if let cached = cachedDiagnostics { return cached }
        let computed = computeDiagnostics()
        cachedDiagnostics = computed
        return computed
    }

    private static func computeDiagnostics() -> Diagnostics {
        let extensions = bundledExtensionInfos()
        let widgetTargetPresent = extensions.contains { $0.extensionPoint == "com.apple.widgetkit-extension" }
        let complicationTargetPresent = extensions.contains { info in
            info.extensionPoint == "com.apple.watchkit"
                || (info.extensionPoint == "com.apple.widgetkit-extension" && info.supportsAccessoryFamilies)
        }
        let appGroupEnabled = hasAppGroupEntitlement()
        return Diagnostics(storage: appGroupEnabled ? "app_group_userdefaults" : "app_local_userdefaults",
                           appGroupEnabled: appGroupEnabled,
                           widgetTargetPresent: widgetTargetPresent,
                           complicationTargetPresent: complicationTargetPresent)
    }

    static func publishFromLaunchIfRequested(store: SessionStore,
                                             ble: AtriaBLEManager,
                                             arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("--atria-log-widget-snapshot") else { return }
        publish(store: store, ble: ble, reason: "launch")
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            publish(store: store, ble: ble, reason: "delayed")
        }
        Task {
            await store.waitForDeferredSessionLoadIfNeeded(timeoutSeconds: 120)
            publish(store: store, ble: ble, reason: "session_load")
        }
    }

    /// A durable morning recovery is immutable for its physiological cycle and
    /// therefore outranks any provisional value that was memoized before the
    /// daily metric/rollup pair finished loading.
    nonisolated static func canonicalRecovery(
        displayed: Metrics.RecoveryEstimate,
        frozen: FrozenRecoverySummary?
    ) -> Metrics.RecoveryEstimate {
        frozen?.recoveryEstimate ?? displayed
    }

    @discardableResult
    static func publish(store: SessionStore,
                        ble: AtriaBLEManager,
                        reason: String = "update",
                        now: Date = Date()) -> WidgetSnapshot {
        // Cold-start strain-flash fix (2026-07-07, device-diagnosed): the
        // volatile live BLE resting reading used to outrank the stable
        // saved-session resting, so the first widget snapshots computed
        // strain from a transient value (86 bpm -> 73) and flashed a wrong
        // number until session load. Stable sources first; the live reading
        // is only the last resort before the session_load republish.
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? ble.restingHR
        let presentationRestingHeartRate = store.currentCycleRestingHeartRateForPresentation(
            on: now
        )
        let validatedHRV = store.latestReferenceValidatedRecoveryHRV(on: now)
        let fallbackHRV = validatedHRV ?? store.latestLocalRecoveryHRV(on: now)
        let latestSleep = store.sleepHistorySnapshot.latestMainSleep
            .flatMap { _ in store.currentPhysiologicalMainSleep(on: now) }
        let latestDisplaySleep = AtriaOverviewCurrentSleep.resolveDisplayEvidence(
            from: store.sleepHistorySnapshot,
            now: now
        )
        let calendar = Calendar.current
        let physiologicalCycle = AtriaPhysiologicalCycle.current(now: now,
                                                                 confirmedSleeps: store.confirmedSleeps,
                                                                 calendar: calendar)
        let frozenRecovery = DailyRecoveryResolver.summary(
            rollups: store.dailyRollupHistory,
            metrics: store.dailyMetricHistory,
            physiologicalCycle: physiologicalCycle,
            anchorSleep: latestSleep,
            calendar: calendar
        )
        // Resolve the durable wake-to-wake summary before evaluating the
        // provisional projection, then carry one complete estimate through the
        // entire snapshot. This is intentionally defensive: a widget publish
        // can race deferred daily-metric settlement, and mixing the provisional
        // score/detail/confidence with a newly available frozen summary made
        // Home show 39 while the widget persisted 42 on the same device.
        let displayedRecovery = store.recoveryProjection(
            now: now,
            calendar: calendar,
            initialFallbackHRVSnapshot: ble.recoveryHRVSnapshot,
            liveRestingHeartRate: ble.restingHR
        )
        let widgetRecovery = canonicalRecovery(
            displayed: displayedRecovery,
            frozen: frozenRecovery
        )
        let recoveryPercent = widgetRecovery.percent
        let frozenTodayRollup = store.dailyRollupHistory.first {
            physiologicalCycle.boundaryKind == .mainSleep
                && calendar.isDate($0.day, inSameDayAs: physiologicalCycle.start)
                && $0.recovery != nil
        }
        let savedAggregate = store.homeSavedAggregate(rest: rest ?? 60,
                                                       maxHR: store.profile.maxHR,
                                                       activeSessionID: ble.currentLiveSessionID,
                                                       calendar: calendar,
                                                       now: now)
        let strain = dayStrain(saved: savedAggregate,
                               store: store,
                               ble: ble,
                               rest: rest ?? 60)
        let wearCoverage = AtriaHomeModel.dayWearCoverageFraction(
            observedSeconds: AtriaHomeModel.observedHeartRateUnionSeconds(
                sessions: store.sessions,
                windowStart: savedAggregate.day,
                windowEnd: now
            )
                + Double(ble.session.count),
            dayElapsedSeconds: now.timeIntervalSince(savedAggregate.day)
        )
        let baseStrainConfidence = AtriaHomeModel.strainConfidence(
            hasRestingHeartRateEvidence: rest != nil,
            maxHRSource: store.profile.maxHRSource,
            hasLoadEvidence:
                savedAggregate.hasSavedToday || ble.session.count >= 60,
            resolvedRest: rest ?? 60,
            maxHR: store.profile.maxHR,
            wearCoverageFraction: wearCoverage
        )
        let strainPresentation = Metrics.StrainPresentation.resolve(
            value: strain,
            coverageFraction: wearCoverage,
            baseConfidence: baseStrainConfidence,
            additionalIncompleteEvidence: AtriaWorkoutMetricPresentation.cycleStrainIsIncomplete(
                start: physiologicalCycle.start,
                end: now,
                strain: strain,
                workouts: store.confirmedWorkouts
            )
        )
        let strainConfidence = strainPresentation.confidence
        let strainIsCredible =
            !strainConfidence.localizedCaseInsensitiveContains("learning")
                && !strainConfidence.localizedCaseInsensitiveContains("standby")
        let strainIsPartial =
            strainConfidence.localizedCaseInsensitiveContains("partial")
        let strainDetail: String? = strainIsCredible
            ? (strainIsPartial
                ? strainPresentation.coverageText ?? "Partial · sparse HR"
                : "Current cycle")
            : nil
        let strapStepsToday = AtriaHomeModel.mergedStrapStepResearchCount(
            savedToday: savedAggregate.savedTodayStrapSteps,
            savedActiveSession: savedAggregate.savedActiveSessionStrapSteps,
            savedActiveSessionTotal: savedAggregate.savedActiveSessionTotalStrapSteps,
            liveActiveSession: ble.liveStrapStepResearchCount
        )
        let projectedStepDays: [
            AtriaHistoricalDailyConsumerProjection.StepDay
        ]
        let qualifiedHistoricalStepDays =
            AtriaWhoop4MotionTickDailyStore.shared
                .removingUnqualifiedResearchEvidence(
                    from: store.historySnapshot
                        .verifiedHistoricalStepEvidenceDays
                )
        let strapIdentifiers =
            AtriaWhoop4MotionTickDailyStore.persistedStrapIdentifiers()
        let stepReleaseAuthorityQualified =
            AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified
        let currentCycleReceipt:
            AtriaWhoop4MotionTickDailyStore.PublicationReceipt?
        let currentCycleDisplayedReceiptContentRevision: String?
        let currentCycleReceiptInvalidatesIndependentPartial: Bool
        if !strapIdentifiers.isEmpty {
            let publication = AtriaWhoop4MotionTickDailyStore.shared
                .currentCyclePublication(
                    into: qualifiedHistoricalStepDays,
                    strapIdentifiers: strapIdentifiers,
                    windowStart: savedAggregate.day,
                    now: now,
                    calendar: calendar
                )
            projectedStepDays = publication.projectedDays
            currentCycleReceipt = publication.receipt
            currentCycleDisplayedReceiptContentRevision =
                publication.displayedReceiptContentRevision
            currentCycleReceiptInvalidatesIndependentPartial =
                publication.receiptInvalidatesIndependentPartial
        } else {
            projectedStepDays = qualifiedHistoricalStepDays
            currentCycleReceipt = nil
            currentCycleDisplayedReceiptContentRevision = nil
            currentCycleReceiptInvalidatesIndependentPartial = false
        }
        let currentCycleReceiptCapturedAt =
            currentCycleReceipt?.evidence.capturedThrough
        let currentCycleReceiptContentRevision =
            currentCycleReceipt?.contentRevision
        // 2026-07-31: disclosure-only prior-cycle receipt. Kept out of
        // projectedStepDays so `steps` stays nil (honest) after a no-sleep
        // rollover; only the widget's detail line may name the prior count.
        let priorCycleReceipt = strapIdentifiers.isEmpty
            ? nil
            : AtriaWhoop4MotionTickDailyStore.shared.latestReceipt(
                before: savedAggregate.day,
                strapIdentifiers: strapIdentifiers
            )
        let dailySteps = resolvedDailySteps(
            day: now,
            now: now,
            liveCount: strapStepsToday,
            liveValidationState: ble.liveStrapStepResearchState,
            liveCapturedAt: ble.liveStrapStepCountCapturedAt,
            canonicalDays: projectedStepDays,
            liveAuthorityQualified:
                stepReleaseAuthorityQualified,
            physiologicalDayStart: savedAggregate.day,
            priorCycleReceipt: priorCycleReceipt.map {
                .init(steps: $0.steps, endedAt: $0.capturedThrough)
            },
            calendar: calendar
        )
        let liveHeartRate = AtriaHomeModel.resolvedLiveHeartRate(
            heartRate: ble.heartRate,
            sensorHasContact: ble.hasContact,
            status: ble.status,
            latestSampleHeartRate: ble.session.last?.bpm,
            latestSampleAt: ble.session.last?.t
        )
        let liveHeartRateCapturedAt = liveHeartRate > 0 ? ble.session.last?.t : nil
        let liveHeartRateZone = liveHeartRate > 0
            ? HRZone.zone(for: liveHeartRate,
                          maxHR: store.profile.maxHR,
                          restingHR: presentationRestingHeartRate ?? rest)
            : nil
        let publishedSteps = dailySteps.count
        let stepsAreValidated = dailySteps.isValidated
        let stepsCapturedAt = dailySteps.capturedAt
        let displayedReceiptContentRevision = publishedSteps != nil
            && stepsCapturedAt == currentCycleReceiptCapturedAt
            && publishedSteps == currentCycleReceipt?.evidence.steps
            && stepSourceIdentifier(dailySteps.source)
                == "verifiedCanonical"
            ? currentCycleDisplayedReceiptContentRevision : nil
        let storedDailyStepGoal = UserDefaults.standard.integer(forKey: "atria.target.steps.goal")
        let dailyStepGoal = storedDailyStepGoal > 0 ? storedDailyStepGoal : 8_000
        let hrvRMSSD: Int?
        if let frozenRecovery {
            hrvRMSSD = frozenRecovery.usesHRV
                ? frozenTodayRollup?.lnRMSSD.map { Int(exp($0).rounded()) }
                : nil
        } else if widgetRecovery.usesHRV {
            if let snapshot = ble.hrvSnapshot, snapshot.isDisplayEligible(on: now) {
                hrvRMSSD = Int(snapshot.rmssd.rounded())
            } else {
                hrvRMSSD = fallbackHRV
            }
        } else {
            hrvRMSSD = nil
        }
        let hrvState: String
        if hrvRMSSD == nil {
            hrvState = "learning"
        } else {
            hrvState = widgetRecovery.confidence == .validated ? "validated" : "personal_baseline"
        }
        let layout = currentHomeLayoutConfig()
        let widgetDiagnostics = Self.diagnostics
        let defaults = widgetDiagnostics.appGroupEnabled
            ? (UserDefaults(suiteName: appGroupID) ?? .standard)
            : .standard
        let strainCycleExpiresAt = cumulativeStrainCycleExpiration(
            cycle: physiologicalCycle,
            confirmedSleeps: store.confirmedSleeps,
            calendar: calendar
        )
        // `displayableBatteryLevel` already fails closed unless the level is a
        // validated mid-range packet or the running app is renewing a proven
        // change-driven 2A19 lease. Re-applying the older "recent baseline"
        // veto here made widgets disagree with the app and show Learning while
        // the same connected strap truthfully showed 12% · Low.
        let displayableBatteryLevel = ble.displayableBatteryLevel()
        let persistedBattery = AtriaBLEManager.cachedBattery(now: now)
        let displayableChargeStatus = displayableBatteryLevel == nil
            ? AtriaBLEManager.BatteryChargeStatus.levelOnly
            : ble.batteryChargeStatus
        let batteryChargeCapturedAt = displayableBatteryLevel != nil
            && (displayableChargeStatus == .charging || displayableChargeStatus == .full)
            && persistedBattery.chargeAge >= 0
            ? now.addingTimeInterval(-persistedBattery.chargeAge)
            : nil
        // Optional evidence qualifiers are an additive schema-4 extension so
        // already-installed widget extensions continue decoding the payload.
        var snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: now,
                                      recoveryPercent: recoveryPercent,
                                      recoveryConfidence: widgetRecovery.confidence.rawValue,
                                      recoveryDetail: widgetRecovery.detail,
                                      strain: strain,
                                      strainDetail: strainDetail,
                                      // `dayStrain` was recomputed immediately
                                      // above; this is its true computation
                                      // clock, not a generic snapshot fallback.
                                      // Without resting-HR evidence or a max HR
                                      // above rest, TRIMP integrates against a
                                      // fabricated anchor and reads a confident
                                      // 0.0 — withhold the credibility clock so
                                      // the widget shows its placeholder, the
                                      // same honesty gate as the Home hero.
                                      strainCapturedAt: strainIsCredible ? now : nil,
                                      strainCycleStart: strainIsCredible ? physiologicalCycle.start : nil,
                                      strainCycleExpiresAt: strainIsCredible ? strainCycleExpiresAt : nil,
                                      restingHR: presentationRestingHeartRate,
                                      hrvRMSSD: hrvRMSSD,
                                      hrvState: hrvState,
                                      maxHR: store.profile.maxHR,
                                      sleepHours: latestDisplaySleep?.durationHours,
                                      sleepDetail: latestDisplaySleep.map {
                                        $0.confirmed ? "Confirmed sleep" : ($0.isNapEvidence ? "Review nap" : "Review sleep")
                                      },
                                      steps: publishedSteps,
                                      // Old widget processes do not understand
                                      // the additive lower-bound qualifier.
                                      // Mark a canonical partial as estimated
                                      // there so it cannot appear exact; current
                                      // widgets render the stronger `≥` label.
                                      stepsAreEstimated: publishedSteps == nil ? nil
                                        : (!stepsAreValidated
                                            || (dailySteps.source == .verifiedCanonical
                                                && dailySteps.completeness == .partial)),
                                      stepsCapturedAt: stepsCapturedAt,
                                      stepsSource: stepSourceIdentifier(dailySteps.source),
                                      stepsCompleteness: stepCompletenessIdentifier(dailySteps.completeness),
                                      stepsCoverageFraction: dailySteps.coverageFraction,
                                      stepsAuthorityVersion: publishedSteps == nil
                                        ? nil : qualifiedStepAuthorityVersion,
                                      stepsCycleStart: publishedSteps == nil ? nil : physiologicalCycle.start,
                                      stepsCycleExpiresAt: publishedSteps == nil ? nil : strainCycleExpiresAt,
                                      stepsReceiptAuthorityVersion:
                                        strapIdentifiers.isEmpty
                                            || !stepReleaseAuthorityQualified
                                            ? nil : qualifiedStepAuthorityVersion,
                                      stepsReceiptSourceIdentifier:
                                        stepReleaseAuthorityQualified
                                            ? strapIdentifiers.first : nil,
                                      stepsReceiptCycleStart:
                                        strapIdentifiers.isEmpty
                                            || !stepReleaseAuthorityQualified
                                            ? nil : physiologicalCycle.start,
                                      stepsReceiptCapturedAt:
                                        currentCycleReceiptCapturedAt,
                                      stepsReceiptContentRevision:
                                        currentCycleReceiptContentRevision,
                                      stepsDisplayedReceiptContentRevision:
                                        displayedReceiptContentRevision,
                                      stepsReceiptInvalidatesIndependentPartial:
                                        currentCycleReceiptInvalidatesIndependentPartial,
                                      stepsPriorCycleSteps: dailySteps
                                        .priorCycleReceipt?.steps,
                                      stepsPriorCycleEndedAt: dailySteps
                                        .priorCycleReceipt?.endedAt,
                                      dailyStepGoal: dailyStepGoal,
                                      heartRate: liveHeartRate > 0 ? liveHeartRate : nil,
                                      heartRateCapturedAt: liveHeartRateCapturedAt,
                                      heartRateZoneIndex: liveHeartRateZone?.rawValue,
                                      heartRateZoneName: liveHeartRateZone?.name,
                                      batteryLevel: displayableBatteryLevel,
                                      batteryCapturedAt: displayableBatteryLevel == nil ? nil : ble.lastVerifiedBatteryLevelAt,
                                      batteryCorroboratedAt: displayableBatteryLevel == nil
                                        ? nil : ble.batteryDisplayCorroboratedAt(),
                                      batteryChargeCapturedAt: batteryChargeCapturedAt,
                                      batteryChargeStatus: displayableChargeStatus.rawValue,
                                      batteryChargeText: displayableChargeStatus.label,
                                      layoutGlanceMetrics: layout.glanceMetrics,
                                      layoutRingCenterMetric: layout.ringCenterMetric.rawValue,
                                      layoutLegendStatStyle: layout.legendStatStyle.rawValue,
                                      layoutAccent: layout.accent.rawValue,
                                      storage: widgetDiagnostics.storage,
                                      appGroupEnabled: widgetDiagnostics.appGroupEnabled,
                                      widgetTargetPresent: widgetDiagnostics.widgetTargetPresent,
                                      complicationTargetPresent: widgetDiagnostics.complicationTargetPresent)
        // Cold-start + card-settlement guard: landing sessions makes the UI
        // interactive before the async confirmed-sleep -> metric -> rollup chain
        // is complete. Preserve the last durable widget until both authorities
        // are ready; the verified settlement callback republishes immediately.
        if !shouldPersistSnapshot(
            hasLoadedSavedSessions: store.hasLoadedSavedSessions,
            hasLoadedRecoveryHistory: store.hasLoadedRecoveryHistory,
            deferredLaunchCardSettlementPending: store.deferredLaunchCardSettlementPending
        ) {
            let awaiting: String
            if !store.hasLoadedSavedSessions {
                awaiting = "session_load"
            } else if !store.hasLoadedRecoveryHistory {
                awaiting = "recovery_history"
            } else {
                awaiting = "card_settlement"
            }
            AtriaDebugLog("ATRIADBG widget_snapshot status=deferred reason=%@ awaiting=%@", reason, awaiting)
            return snapshot
        }
        // Re-read the durable receipt after the broad/card computation. A
        // correction can retain its capture clock, so the content revision is
        // the only honest tie-break against a broad candidate that began first.
        let authoritativeReceiptContentRevision = strapIdentifiers.isEmpty
            ? nil
            : AtriaWhoop4MotionTickDailyStore.shared
                .currentCyclePublication(
                    into: [],
                    strapIdentifiers: strapIdentifiers,
                    windowStart: savedAggregate.day,
                    now: max(now, Date()),
                    calendar: calendar
                ).receipt?.contentRevision
        if let currentData = defaults.data(forKey: key),
           let current = try? JSONDecoder.widgetSnapshotDecoder.decode(
            WidgetSnapshot.self,
            from: currentData
           ) {
            snapshot = snapshotPreservingFresherStepAuthority(
                candidate: snapshot,
                current: current,
                authoritativeReceiptContentRevision:
                    authoritativeReceiptContentRevision
            )
        }
        if let data = try? JSONEncoder.widgetSnapshotEncoder.encode(snapshot) {
            defaults.set(data, forKey: key)
            AtriaDebugLog("ATRIADBG widget_snapshot status=ok reason=%@ schema=%d recovery=%@ confidence=%@ hrv=%@ strain=%.1f rhr=%@ max_hr=%d battery=%@ charge=%@ bytes=%d storage=%@ app_group=%d widget_target=%d complication_target=%d",
                          reason,
                          snapshot.schema,
                          formatInt(snapshot.recoveryPercent),
                          snapshot.recoveryConfidence,
                          hrvState,
                          snapshot.strain,
                          formatInt(snapshot.restingHR),
                          snapshot.maxHR,
                          formatInt(snapshot.batteryLevel),
                          snapshot.batteryChargeStatus ?? "unknown",
                          data.count,
                          snapshot.storage,
                          snapshot.appGroupEnabled ? 1 : 0,
                          snapshot.widgetTargetPresent ? 1 : 0,
                          snapshot.complicationTargetPresent ? 1 : 0)
            let readinessAction = widgetReadinessAction(diagnostics: widgetDiagnostics)
            let readinessStatus = widgetDiagnostics.appGroupEnabled
                && widgetDiagnostics.widgetTargetPresent
                && widgetDiagnostics.complicationTargetPresent ? "ready" : "diagnostic_only"
            AtriaDebugLog("ATRIADBG widget_readiness status=%@ storage=%@ app_group=%d widget_target=%d complication_target=%d action=%@",
                          readinessStatus,
                          snapshot.storage,
                          snapshot.appGroupEnabled ? 1 : 0,
                          snapshot.widgetTargetPresent ? 1 : 0,
                          snapshot.complicationTargetPresent ? 1 : 0,
                          readinessAction)
#if canImport(WidgetKit)
            if widgetDiagnostics.appGroupEnabled {
                scheduleTimelineReload(for: snapshot)
            }
#endif
        } else {
            AtriaDebugLog("ATRIADBG widget_snapshot status=error reason=encode_failed")
        }
        return snapshot
    }

    nonisolated static func shouldPersistSnapshot(
        hasLoadedSavedSessions: Bool,
        hasLoadedRecoveryHistory: Bool,
        deferredLaunchCardSettlementPending: Bool
    ) -> Bool {
        hasLoadedSavedSessions
            && hasLoadedRecoveryHistory
            && !deferredLaunchCardSettlementPending
    }

    nonisolated static func strapStepsAreValidated(state: String) -> Bool {
        state == "validated"
            || state == "r10_live_validated"
    }

    /// Widgets and the in-app Steps card use the same strap-only policy.
    nonisolated static func resolvedDailySteps(
        day: Date,
        now: Date,
        liveCount: Int,
        liveValidationState: String,
        liveCapturedAt: Date?,
        canonicalDays: [AtriaHistoricalDailyConsumerProjection.StepDay] = [],
        liveAuthorityQualified: Bool = true,
        physiologicalDayStart: Date? = nil,
        priorCycleReceipt: AtriaDailyStepPresentation.PriorCycleReceipt? = nil,
        calendar: Calendar = .current
    ) -> AtriaDailyStepPresentation {
        AtriaDailyStepPresentation.resolve(
            day: day,
            now: now,
            liveCount: liveCount,
            liveValidationState: liveValidationState,
            liveCapturedAt: liveCapturedAt,
            canonicalDays: canonicalDays,
            liveAuthorityQualified: liveAuthorityQualified,
            physiologicalDayStart: physiologicalDayStart,
            priorCycleReceipt: priorCycleReceipt,
            calendar: calendar
        )
    }

    nonisolated static func stepSourceIdentifier(
        _ source: AtriaDailyStepPresentation.Source
    ) -> String? {
        switch source {
        case .live: return "live"
        case .verifiedCanonical: return "verifiedCanonical"
        case .none: return nil
        }
    }

    nonisolated static func stepCompletenessIdentifier(
        _ completeness: AtriaDailyStepPresentation.Completeness
    ) -> String? {
        switch completeness {
        case .complete: return "complete"
        case .partial: return "partial"
        case .unavailable: return nil
        }
    }

    nonisolated static func strapStepsArePublishable(state: String) -> Bool {
        strapStepsAreValidated(state: state)
            || state == "r10_live_preliminary"
    }

    /// Live writes can arrive every five seconds. WidgetKit cannot sustainably
    /// reload at that frequency, so exact step/HR progress and their independent
    /// capture clocks share a one-minute delivery cadence. Non-sensor changes
    /// (recovery, strain, battery, layout, source availability, HR zone, step
    /// goal) remain immediate.
    nonisolated static let liveSensorTimelineReloadMinimumInterval: TimeInterval = 60
    nonisolated static let timelineReloadMaximumInterval: TimeInterval = 15 * 60

    /// `0` means reload now, a positive value means preserve a trailing reload
    /// after that delay, and `nil` means there is no new visible state to send.
    /// Kept pure for regression coverage of short walks and same-value capture
    /// clock renewals.
    nonisolated static func timelineReloadDelay(previous: WidgetSnapshot?,
                                                lastReloadAt: Date?,
                                                snapshot: WidgetSnapshot,
                                                now: Date) -> TimeInterval? {
        guard let previous, let lastReloadAt else { return 0 }
        if timelineTransitionFingerprint(for: previous)
            != timelineTransitionFingerprint(for: snapshot) {
            return 0
        }

        let sensorProjectionChanged = previous.steps != snapshot.steps
            || previous.stepsCapturedAt != snapshot.stepsCapturedAt
            || previous.stepsCoverageFraction != snapshot.stepsCoverageFraction
            || previous.stepsAuthorityVersion
                != snapshot.stepsAuthorityVersion
            || previous.heartRate != snapshot.heartRate
            || previous.heartRateCapturedAt != snapshot.heartRateCapturedAt
            || previous.batteryCapturedAt != snapshot.batteryCapturedAt
            || previous.batteryCorroboratedAt != snapshot.batteryCorroboratedAt
            || previous.batteryChargeCapturedAt != snapshot.batteryChargeCapturedAt
            || previous.strainCapturedAt != snapshot.strainCapturedAt
        let elapsed = max(0, now.timeIntervalSince(lastReloadAt))
        if sensorProjectionChanged {
            return elapsed >= liveSensorTimelineReloadMinimumInterval
                ? 0
                : liveSensorTimelineReloadMinimumInterval - elapsed
        }
        return elapsed >= timelineReloadMaximumInterval ? 0 : nil
    }

    private nonisolated static func timelineTransitionFingerprint(for snapshot: WidgetSnapshot) -> String {
        var parts: [String] = []
        parts.append(snapshot.recoveryPercent.map(String.init) ?? "learning")
        parts.append(snapshot.recoveryConfidence)
        parts.append(String(format: "%.1f", snapshot.strain))
        parts.append(snapshot.strainDetail ?? "strain_detail_absent")
        parts.append(snapshot.strainCycleStart.map { String($0.timeIntervalSince1970) } ?? "strain_cycle_absent")
        parts.append(snapshot.strainCycleExpiresAt.map { String($0.timeIntervalSince1970) } ?? "strain_expiry_absent")
        parts.append(snapshot.restingHR.map(String.init) ?? "-")
        parts.append(snapshot.hrvRMSSD.map(String.init) ?? "-")
        parts.append(snapshot.sleepHours.map { String(format: "%.1f", $0) } ?? "-")
        parts.append(snapshot.sleepDetail ?? "sleep_detail_absent")
        // Exact step/HR values and capture clocks are handled by the bounded
        // sensor lane above. Presence and semantic transitions stay immediate.
        parts.append(snapshot.steps == nil ? "steps_absent" : "steps_present")
        parts.append(snapshot.stepsCapturedAt == nil ? "motion_clock_absent" : "motion_clock_present")
        parts.append(snapshot.stepsAreEstimated == false ? "validated" : "estimated")
        parts.append(snapshot.stepsSource ?? "legacy_source")
        parts.append(snapshot.stepsCompleteness ?? "legacy_completeness")
        parts.append(
            snapshot.stepsAuthorityVersion ?? "steps_authority_absent"
        )
        parts.append(snapshot.stepsCycleStart.map { String($0.timeIntervalSince1970) } ?? "steps_cycle_absent")
        parts.append(snapshot.stepsCycleExpiresAt.map { String($0.timeIntervalSince1970) } ?? "steps_expiry_absent")
        parts.append(snapshot.dailyStepGoal.map(String.init) ?? "-")
        let exactDailyStepGoalReached = snapshot.stepsAreEstimated == false
            && snapshot.stepsCompleteness != "partial"
            && snapshot.dailyStepGoal.map { goal in
                goal > 0 && (snapshot.steps ?? 0) >= goal
            } == true
        parts.append(exactDailyStepGoalReached ? "step_goal_reached" : "step_goal_pending")
        parts.append(snapshot.heartRate == nil ? "hr_absent" : "hr_present")
        parts.append(snapshot.heartRateCapturedAt == nil ? "hr_clock_absent" : "hr_clock_present")
        parts.append(snapshot.heartRateZoneIndex.map(String.init) ?? "-")
        let batteryBucket: String = snapshot.batteryLevel.map { String(($0 / 10) * 10) } ?? "-"
        parts.append(batteryBucket)
        parts.append(snapshot.batteryChargeStatus ?? "-")
        parts.append(snapshot.layoutGlanceMetrics?.joined(separator: ",") ?? "-")
        parts.append(snapshot.layoutRingCenterMetric ?? "-")
        parts.append(snapshot.layoutLegendStatStyle ?? "-")
        parts.append(snapshot.layoutAccent ?? "-")
        return parts.joined(separator: "|")
    }

#if canImport(WidgetKit)
    private static func scheduleTimelineReload(for snapshot: WidgetSnapshot,
                                               now: Date = Date()) {
        let delay = timelineReloadDelay(previous: lastTimelineReloadSnapshot,
                                        lastReloadAt: lastTimelineReloadDate,
                                        snapshot: snapshot,
                                        now: now)
        guard let delay else { return }
        if delay <= 0 {
            pendingTimelineReloadTask?.cancel()
            pendingTimelineReloadTask = nil
            pendingTimelineReloadSnapshot = nil
            pendingTimelineReloadDeadline = nil
            deliverTimelineReload(snapshot, now: now)
            return
        }

        pendingTimelineReloadSnapshot = snapshot
        let deadline = now.addingTimeInterval(delay)
        if let currentDeadline = pendingTimelineReloadDeadline,
           currentDeadline <= deadline,
           pendingTimelineReloadTask != nil {
            return
        }
        pendingTimelineReloadTask?.cancel()
        pendingTimelineReloadDeadline = deadline
        pendingTimelineReloadTask = Task { @MainActor in
            let sleep = max(0, deadline.timeIntervalSinceNow)
            if sleep > 0 {
                try? await Task.sleep(for: .seconds(sleep))
            }
            guard !Task.isCancelled else { return }
            let latest = pendingTimelineReloadSnapshot ?? snapshot
            pendingTimelineReloadTask = nil
            pendingTimelineReloadSnapshot = nil
            pendingTimelineReloadDeadline = nil
            deliverTimelineReload(latest, now: Date())
        }
    }

    private static func deliverTimelineReload(_ snapshot: WidgetSnapshot,
                                              now: Date) {
        lastTimelineReloadSnapshot = snapshot
        lastTimelineReloadDate = now
        WidgetCenter.shared.reloadAllTimelines()
    }
#endif

    // Perf (overnight-hang fix): dayStrain previously recomputed live-session
    // TRIMP over the ENTIRE in-memory `ble.session` array on every publish (~3s
    // cadence while foregrounded). Across a night that array grows to tens of
    // thousands of samples, so the O(n) map + exp() loop ran on the main actor
    // and produced accumulating frame hangs. We now keep an incremental
    // accumulator (mirrors AtriaHomeView.nextLiveSessionDerived) keyed on the
    // sample prefix, so each publish only integrates the NEW samples. State is
    // MainActor-isolated like `cachedDiagnostics`, so writes are race-free.
    private static var liveTRIMPSampleCount = 0
    private static var liveTRIMPLastTimestamp: Date?
    private static var liveTRIMPRest = 0
    private static var liveTRIMPMax = 0
    private static var liveTRIMPSex: AthleteProfile.BiologicalSex = .unspecified
    private static var liveTRIMPCycleStart: Date?
    private static var liveTRIMPValue = 0.0

    /// Preserve the cumulative clock when a live patch only changes HR, steps,
    /// battery, or another unrelated field. A changed aggregate may advance
    /// only from its explicit load-evidence clock; `createdAt` is intentionally
    /// not accepted as a fallback here.
    nonisolated static func cumulativeStrainCaptureDate(
        previousValue: Double?,
        previousCapturedAt: Date?,
        nextValue: Double,
        nextEvidenceAt: Date?
    ) -> Date? {
        guard let previousValue,
              abs(previousValue - nextValue) <= 0.000_000_001 else {
            return nextEvidenceAt
        }
        return previousCapturedAt ?? nextEvidenceAt
    }

    nonisolated static func cumulativeStrainCycleExpiration(
        cycle: AtriaPhysiologicalCycle,
        confirmedSleeps: [UserConfirmedSleep],
        calendar: Calendar
    ) -> Date {
        let cycleCalendar: Calendar
        if let anchorID = cycle.anchorSleepID,
           let anchor = confirmedSleeps.first(where: { $0.id == anchorID }) {
            cycleCalendar = EventCivilTime.eventCalendar(
                timeZoneIdentifier: anchor.eventTimeZoneIdentifier,
                fallback: calendar
            )
        } else {
            cycleCalendar = calendar
        }
        // `AtriaPhysiologicalCycle.current` advances the no-sleep boundary by
        // one civil day in this same event calendar. Persist that exact future
        // boundary so WidgetKit cannot keep yesterday's load current-looking.
        return cycleCalendar.date(byAdding: .day, value: 1, to: cycle.start)
            ?? cycle.start.addingTimeInterval(AtriaPhysiologicalCycle.maximumLearnedInterval)
    }

    private static func dayStrain(saved: SessionStore.HomeSavedAggregate,
                                  store: SessionStore,
                                  ble: AtriaBLEManager,
                                  rest: Int) -> Double {
        let live = incrementalLiveTRIMP(samples: ble.session,
                                        rest: rest,
                                        max: store.profile.maxHR,
                                        sex: store.profile.biologicalSex,
                                        cycleStart: saved.day)
        let reconciled = SessionStore.mergedTodayTRIMP(
            savedToday: saved.savedTodayTRIMP,
            savedActiveSession: saved.savedActiveSessionTRIMP,
            liveActiveSession: live
        )
        return Metrics.strain(fromTRIMP: reconciled)
    }

    /// Same TRIMP math as `Metrics.trimp` / `AtriaHomeView.liveSessionTRIMP`, but
    /// extends a cached running total instead of re-integrating the whole array.
    /// Falls back to a full recompute when the sample prefix, rest, or max HR no
    /// longer match the cached state (e.g. after a live-session rollover clears
    /// `ble.session`, or the resting/max baseline changed).
    // Internal (was private) so LocalNotificationScheduler reuses this same
    // incremental accumulator instead of re-integrating the whole live session
    // (2026-07-08 perf audit). Both are @MainActor, so the cache stays race-free.
    static func incrementalLiveTRIMP(samples: [HRSample],
                                     rest: Int,
                                     max: Int,
                                     sex: AthleteProfile.BiologicalSex = .unspecified,
                                     cycleStart: Date? = nil) -> Double {
        guard max > rest, samples.count > 1 else {
            liveTRIMPSampleCount = samples.count
            liveTRIMPLastTimestamp = samples.last?.t
            liveTRIMPRest = rest
            liveTRIMPMax = max
            liveTRIMPSex = sex
            liveTRIMPCycleStart = cycleStart
            liveTRIMPValue = 0
            return 0
        }
        let canExtend = rest == liveTRIMPRest
            && max == liveTRIMPMax
            && sex == liveTRIMPSex
            && cycleStart == liveTRIMPCycleStart
            && liveTRIMPSampleCount > 0
            && liveTRIMPSampleCount <= samples.count
            && liveTRIMPLastTimestamp == samples[liveTRIMPSampleCount - 1].t
        let strainParameters = AtriaAnalytics.Strain.banisterParameters(for: sex)
        let strainConfiguration = AtriaStrainLoadModel.Configuration(
            restingBPM: Double(rest),
            maximumBPM: Double(max),
            intensityMultiplier: strainParameters.multiplier,
            intensityCoefficient: strainParameters.coefficient,
            mode: .continuousDay,
            maximumGap: AtriaAnalytics.Strain.maximumLoadEvidenceGap
        )
        var total = canExtend ? liveTRIMPValue : 0
        var index = canExtend ? liveTRIMPSampleCount : 1
        while index < samples.count {
            let insideCycle = cycleStart.map {
                samples[index - 1].t >= $0 && samples[index].t >= $0
            } ?? true
            if insideCycle {
                total += AtriaStrainLoadModel.evaluateInterval(
                    from: AtriaStrainLoadModel.Sample(
                        timestamp: samples[index - 1].t.timeIntervalSinceReferenceDate,
                        bpm: Double(samples[index - 1].bpm)
                    ),
                    to: AtriaStrainLoadModel.Sample(
                        timestamp: samples[index].t.timeIntervalSinceReferenceDate,
                        bpm: Double(samples[index].bpm)
                    ),
                    configuration: strainConfiguration
                ).load
            }
            index += 1
        }
        liveTRIMPSampleCount = samples.count
        liveTRIMPLastTimestamp = samples.last?.t
        liveTRIMPRest = rest
        liveTRIMPMax = max
        liveTRIMPSex = sex
        liveTRIMPCycleStart = cycleStart
        liveTRIMPValue = total
        return total
    }

    private static func currentHomeLayoutConfig() -> AtriaHomeLayoutConfig {
        guard let data = UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey)?.data(using: .utf8),
              let config = try? AtriaHomeLayoutConfig.decoded(from: data) else {
            return .default.validated()
        }
        return config
    }

    private static func formatInt(_ value: Int?) -> String {
        value.map(String.init) ?? "learning"
    }

    private static func widgetReadinessAction(diagnostics: Diagnostics) -> String {
        var actions: [String] = []
        if !diagnostics.widgetTargetPresent {
            actions.append("add_widgetkit_target")
        }
        if !diagnostics.appGroupEnabled {
            actions.append("enable_shared_app_group")
        }
        if !diagnostics.complicationTargetPresent {
            actions.append("add_complication_target")
        }
        return actions.isEmpty ? "verify_widget_on_device" : actions.joined(separator: "+")
    }

    private struct BundledExtensionInfo {
        let extensionPoint: String
        let supportsAccessoryFamilies: Bool
    }

    private static func bundledExtensionInfos() -> [BundledExtensionInfo] {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: pluginsURL,
                                                                       includingPropertiesForKeys: nil) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "appex",
                  let bundle = Bundle(url: url),
                  let extensionInfo = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                  let identifier = extensionInfo["NSExtensionPointIdentifier"] as? String else {
                return nil
            }
            let supportsAccessory =
                (bundle.object(forInfoDictionaryKey: "AtriaWidgetSupportsAccessoryFamilies") as? Bool) == true
            return BundledExtensionInfo(extensionPoint: identifier,
                                        supportsAccessoryFamilies: supportsAccessory)
        }
    }

    private static func hasAppGroupEntitlement() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) else {
            return false
        }
        return text.contains(appGroupID)
    }
}

private extension JSONEncoder {
    // Perf (docs/26 follow-up): stored static so the encoder is configured once
    // rather than allocated on every widget publish during live use. Read-only
    // concurrent encodes on an immutable-config encoder are safe.
    static let widgetSnapshotEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let widgetSnapshotDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
