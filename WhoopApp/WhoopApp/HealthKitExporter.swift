import Foundation
import HealthKit

@MainActor
final class HealthKitExporter {
    private let store = HKHealthStore()
    private var pendingAuthorizationRequestID: UUID?

    struct PlannedCounts {
        let hrSamples: Int
        let workouts: Int
        let hrvSamples: Int
        let sleeps: Int
    }

    struct Diagnostics {
        let entitlementPresent: Bool
        let healthDataAvailable: Bool
        let planned: PlannedCounts
        let referenceAudit: ReferenceAuditDiagnostics
        let readback: ReadbackDiagnostics
    }

    struct ReferenceAuditDiagnostics {
        let status: String
        let totalHRSamples: Int
        let atriaHRSamples: Int
        let independentCandidateHRSamples: Int
        let userEnteredHRSamples: Int
        let rejectedUserEnteredHRSamples: Int
        let independentHRSamples: Int
        let independentSources: String
        let validationPairs: Int
        let validationMeanDelta: Double?
        let validationMaxDelta: Double?
        let validationReason: String
        let externalReferenceReady: Bool
    }

    struct ReadbackDiagnostics {
        let status: String
        let reason: String
        let expectedDeltaHRSamples: Int
        let expectedTotalAtriaHRSamples: Int
        let readbackAtriaHRSamples: Int
        let totalHRSamples: Int
        let dataAppears: Bool

        var missingTotalAtriaHRSamples: Int {
            max(expectedTotalAtriaHRSamples - readbackAtriaHRSamples, 0)
        }

        var overfilledTotalAtriaHRSamples: Int {
            max(readbackAtriaHRSamples - expectedTotalAtriaHRSamples, 0)
        }

        var expectedTotalCovered: Bool {
            expectedTotalAtriaHRSamples > 0
            && readbackAtriaHRSamples >= expectedTotalAtriaHRSamples
        }

        var expectedTotalReconciled: Bool {
            expectedTotalAtriaHRSamples > 0
            && readbackAtriaHRSamples == expectedTotalAtriaHRSamples
        }

        var reconciliationStatus: String {
            if expectedTotalAtriaHRSamples <= 0 { return "not_available" }
            if overfilledTotalAtriaHRSamples > 0 { return "overfilled" }
            return expectedTotalReconciled ? "reconciled" : "legacy_backfill_pending"
        }
    }

    private struct HRReferencePoint {
        let t: TimeInterval
        let bpm: Double
    }

    private struct HRReferenceComparison {
        let pairs: Int
        let duration: TimeInterval
        let meanDelta: Double?
        let medianDelta: Double?
        let maxDelta: Double?
        let withinTolerancePercent: Int
        let ready: Bool
        let reason: String
    }

    private struct ExportSnapshot: Codable {
        var hrPointCount: Int
        var hrvExported: Bool
        var workoutExported: Bool
        var end: TimeInterval
    }

    private struct HRBackfillGap {
        let session: SavedSession
        let expected: Int
        let readback: Int

        var missing: Int { max(expected - readback, 0) }
    }

    private typealias ExportLedger = [String: ExportSnapshot]

    private enum ExportLedgerDefaults {
        static let key = "atria.healthkit.exportLedger.v1"
    }

    private var heartRateType: HKQuantityType {
        HKQuantityType.quantityType(forIdentifier: .heartRate)!
    }

    private var hrvType: HKQuantityType {
        HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
    }

    private var workoutType: HKWorkoutType {
        HKObjectType.workoutType()
    }

    private var sleepType: HKCategoryType {
        HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
    }

    func export(sessions: [SavedSession],
                rest: Int,
                maxHR: Int,
                confirmedWorkouts: [UserConfirmedWorkout] = [],
                confirmedSleeps: [UserConfirmedSleep] = []) {
        let diagnostics = HealthKitExporter.diagnostics(for: sessions,
                                                        rest: rest,
                                                        maxHR: maxHR,
                                                        confirmedWorkouts: confirmedWorkouts,
                                                        confirmedSleeps: confirmedSleeps)
        let planned = diagnostics.planned
        guard diagnostics.entitlementPresent else {
            NSLog("WHOOPDBG healthkit_export status=missing_entitlement sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d action=enable_healthkit_capability",
                  sessions.count,
                  planned.hrSamples,
                  planned.workouts,
                  planned.hrvSamples,
                  planned.sleeps)
            return
        }
        guard diagnostics.healthDataAvailable else {
            NSLog("WHOOPDBG healthkit_export status=unavailable sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d",
                  sessions.count,
                  planned.hrSamples,
                  planned.workouts,
                  planned.hrvSamples,
                  planned.sleeps)
            return
        }
        guard !sessions.isEmpty else {
            NSLog("WHOOPDBG healthkit_export status=no_sessions sessions=0 hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d",
                  planned.hrSamples,
                  planned.workouts,
                  planned.hrvSamples,
                  planned.sleeps)
            return
        }

        var ledger = loadExportLedger()
        if ledger.isEmpty,
           diagnostics.referenceAudit.status == "ok",
           diagnostics.referenceAudit.atriaHRSamples >= planned.hrSamples,
           planned.hrSamples > 0,
           confirmedWorkouts.isEmpty,
           confirmedSleeps.isEmpty {
            markSessionsExported(sessions,
                                 confirmedWorkouts: confirmedWorkouts,
                                 confirmedSleeps: confirmedSleeps,
                                 rest: rest,
                                 maxHR: maxHR,
                                 ledger: &ledger)
            saveExportLedger(ledger)
            NSLog("WHOOPDBG healthkit_export status=skipped_existing_atria_samples sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d atria_hr_samples=%d ledger_seeded=1 idempotent=1 action=incremental_exports_only",
                  sessions.count,
                  planned.hrSamples,
                  planned.workouts,
                  planned.hrvSamples,
                  planned.sleeps,
                  diagnostics.referenceAudit.atriaHRSamples)
            verifyHeartRateExportReadback(sessions: sessions,
                                          expectedDeltaHRSamples: 0,
                                          expectedTotalAtriaHRSamples: planned.hrSamples,
                                          rest: rest,
                                          maxHR: maxHR,
                                          reason: "ledger_seeded")
            auditHeartRateReferenceAvailability(sessions: sessions)
            return
        }

        let deltaPlanned = plannedCounts(for: sessions,
                                         confirmedWorkouts: confirmedWorkouts,
                                         confirmedSleeps: confirmedSleeps,
                                         ledger: ledger,
                                         rest: rest,
                                         maxHR: maxHR)
        guard deltaPlanned.hrSamples > 0 || deltaPlanned.workouts > 0 || deltaPlanned.hrvSamples > 0 || deltaPlanned.sleeps > 0 else {
            NSLog("WHOOPDBG healthkit_export status=up_to_date sessions=%d hr_samples=0 workouts=0 hrv_samples=0 sleeps=0 ledger_entries=%d idempotent=1",
                  sessions.count,
                  ledger.count)
            verifyHeartRateExportReadback(sessions: sessions,
                                          expectedDeltaHRSamples: 0,
                                          expectedTotalAtriaHRSamples: planned.hrSamples,
                                          rest: rest,
                                          maxHR: maxHR,
                                          reason: "up_to_date")
            auditHeartRateReferenceAvailability(sessions: sessions)
            return
        }

        let sleepAuthorizationStatus = deltaPlanned.sleeps > 0 ? store.authorizationStatus(for: sleepType) : .sharingAuthorized
        let sleepShareDenied = deltaPlanned.sleeps > 0 && sleepAuthorizationStatus == .sharingDenied
        if sleepShareDenied {
            NSLog("WHOOPDBG healthkit_sleep_export status=permission_required sleeps=%d authorization=%@ action=grant_health_sleep_analysis metric_promotions=0 auto_gate_e_unchanged=1",
                  deltaPlanned.sleeps,
                  Self.authorizationStatusLabel(sleepAuthorizationStatus))
        } else if deltaPlanned.sleeps > 0 && sleepAuthorizationStatus == .notDetermined {
            NSLog("WHOOPDBG healthkit_sleep_export status=authorization_required sleeps=%d authorization=%@ action=request_health_sleep_analysis metric_promotions=0 auto_gate_e_unchanged=1",
                  deltaPlanned.sleeps,
                  Self.authorizationStatusLabel(sleepAuthorizationStatus))
        }
        let writablePlanned = PlannedCounts(hrSamples: deltaPlanned.hrSamples,
                                            workouts: deltaPlanned.workouts,
                                            hrvSamples: deltaPlanned.hrvSamples,
                                            sleeps: sleepShareDenied ? 0 : deltaPlanned.sleeps)
        guard writablePlanned.hrSamples > 0 || writablePlanned.workouts > 0 || writablePlanned.hrvSamples > 0 || writablePlanned.sleeps > 0 else {
            NSLog("WHOOPDBG healthkit_export status=sleep_permission_required sessions=%d hr_samples=0 workouts=0 hrv_samples=0 sleeps=%d ledger_entries=%d idempotent=1 action=grant_health_sleep_analysis",
                  sessions.count,
                  deltaPlanned.sleeps,
                  ledger.count)
            verifyHeartRateExportReadback(sessions: sessions,
                                          expectedDeltaHRSamples: 0,
                                          expectedTotalAtriaHRSamples: planned.hrSamples,
                                          rest: rest,
                                          maxHR: maxHR,
                                          reason: "sleep_permission_required")
            auditHeartRateReferenceAvailability(sessions: sessions)
            return
        }

        let writeTypes = requiredWriteTypes(for: writablePlanned)
        var readTypes: Set<HKObjectType> = [heartRateType]
        if writablePlanned.sleeps > 0 {
            readTypes.insert(sleepType)
        }
        let writeAuthorization = writeAuthorizationState(for: writeTypes)
        if !writeAuthorization.denied.isEmpty {
            NSLog("WHOOPDBG healthkit_export status=share_permission_denied sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d denied=%@ action=grant_health_write_permissions",
                  sessions.count,
                  writablePlanned.hrSamples,
                  writablePlanned.workouts,
                  writablePlanned.hrvSamples,
                  writablePlanned.sleeps,
                  writeAuthorization.denied.joined(separator: ","))
            return
        }
        if writeAuthorization.cached {
            NSLog("WHOOPDBG healthkit_export status=authorization_cached sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d read_hr=1 read_sleep=%d",
                  sessions.count,
                  writablePlanned.hrSamples,
                  writablePlanned.workouts,
                  writablePlanned.hrvSamples,
                  writablePlanned.sleeps,
                  writablePlanned.sleeps > 0 ? 1 : 0)
            writeAuthorizedSessions(sessions,
                                    confirmedWorkouts: confirmedWorkouts,
                                    confirmedSleeps: sleepShareDenied ? [] : confirmedSleeps,
                                    verificationSessions: sessions,
                                    rest: rest,
                                    maxHR: maxHR,
                                    ledger: ledger,
                                    reason: "incremental",
                                    hrOnly: false)
            auditHeartRateReferenceAvailability(sessions: sessions)
            return
        }

        let requestID = UUID()
        pendingAuthorizationRequestID = requestID
        NSLog("WHOOPDBG healthkit_export status=authorization_requested sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d read_hr=1 read_sleep=%d",
              sessions.count,
              writablePlanned.hrSamples,
              writablePlanned.workouts,
              writablePlanned.hrvSamples,
              writablePlanned.sleeps,
              writablePlanned.sleeps > 0 ? 1 : 0)
        scheduleAuthorizationWatchdog(requestID: requestID, sessions: sessions.count, planned: writablePlanned)
        store.requestAuthorization(toShare: writeTypes, read: readTypes) { [weak self] granted, error in
            Task { @MainActor in
                guard let self else { return }
                if self.pendingAuthorizationRequestID == requestID {
                    self.pendingAuthorizationRequestID = nil
                }
                if let error {
                    NSLog("WHOOPDBG healthkit_export status=auth_error sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d error=%@",
                          sessions.count,
                          writablePlanned.hrSamples,
                          writablePlanned.workouts,
                          writablePlanned.hrvSamples,
                          writablePlanned.sleeps,
                          String(describing: error))
                    return
                }
                guard granted else {
                    NSLog("WHOOPDBG healthkit_export status=auth_denied sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d",
                          sessions.count,
                          writablePlanned.hrSamples,
                          writablePlanned.workouts,
                          writablePlanned.hrvSamples,
                          writablePlanned.sleeps)
                    return
                }
                self.writeAuthorizedSessions(sessions,
                                             confirmedWorkouts: confirmedWorkouts,
                                             confirmedSleeps: sleepShareDenied ? [] : confirmedSleeps,
                                             verificationSessions: sessions,
                                             rest: rest,
                                             maxHR: maxHR,
                                             ledger: ledger,
                                             reason: "incremental",
                                             hrOnly: false)
                self.auditHeartRateReferenceAvailability(sessions: sessions)
            }
        }
    }

    func auditHeartRateReferenceFromLaunchIfRequested(arguments: [String], sessions: [SavedSession]) {
        guard arguments.contains("--whoop-healthkit-reference-audit") else { return }
        NSLog("WHOOPDBG healthkit_reference_audit_start sessions=%d source=launch_arg", sessions.count)
        auditHeartRateReferenceAvailability(sessions: sessions)
    }

    func resetAndRebuildAtriaHeartRateFromLaunchIfRequested(arguments: [String],
                                                            sessions: [SavedSession],
                                                            rest: Int,
                                                            maxHR: Int) {
        guard arguments.contains("--whoop-healthkit-reset-rebuild-atria-hr") else { return }
        resetAndRebuildAtriaHeartRate(sessions: sessions, rest: rest, maxHR: maxHR)
    }

    private func requiredWriteTypes(for planned: PlannedCounts) -> Set<HKSampleType> {
        var types: Set<HKSampleType> = []
        if planned.hrSamples > 0 {
            types.insert(heartRateType)
        }
        if planned.hrvSamples > 0 {
            types.insert(hrvType)
        }
        if planned.workouts > 0 {
            types.insert(workoutType)
        }
        if planned.sleeps > 0 {
            types.insert(sleepType)
        }
        return types
    }

    private func writeAuthorizationState(for types: Set<HKSampleType>) -> (cached: Bool, denied: [String]) {
        var denied: [String] = []
        var allAuthorized = true
        for type in types {
            switch store.authorizationStatus(for: type) {
            case .sharingAuthorized:
                continue
            case .sharingDenied:
                allAuthorized = false
                denied.append(healthTypeLabel(type))
            case .notDetermined:
                allAuthorized = false
            @unknown default:
                allAuthorized = false
            }
        }
        return (allAuthorized && !types.isEmpty, denied)
    }

    nonisolated private static func authorizationStatusLabel(_ status: HKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .sharingDenied: return "sharing_denied"
        case .sharingAuthorized: return "sharing_authorized"
        @unknown default: return "unknown"
        }
    }

    private func healthTypeLabel(_ type: HKSampleType) -> String {
        if type == heartRateType {
            return "heart_rate"
        }
        if type == hrvType {
            return "hrv_sdnn"
        }
        if type == workoutType {
            return "workout"
        }
        if type == sleepType {
            return "sleep_analysis"
        }
        return type.identifier.replacingOccurrences(of: " ", with: "_")
    }

    private func scheduleAuthorizationWatchdog(requestID: UUID, sessions: Int, planned: PlannedCounts) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard pendingAuthorizationRequestID == requestID else { return }
            NSLog("WHOOPDBG healthkit_export status=authorization_pending sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d read_hr=1 read_sleep=%d timeout_s=15 action=approve_health_permissions_on_device",
                  sessions,
                  planned.hrSamples,
                  planned.workouts,
                  planned.hrvSamples,
                  planned.sleeps,
                  planned.sleeps > 0 ? 1 : 0)
        }
    }

    static func diagnostics(for sessions: [SavedSession],
                            rest: Int,
                            maxHR: Int,
                            confirmedWorkouts: [UserConfirmedWorkout] = [],
                            confirmedSleeps: [UserConfirmedSleep] = []) -> Diagnostics {
        Diagnostics(entitlementPresent: hasHealthKitEntitlement(),
                    healthDataAvailable: HKHealthStore.isHealthDataAvailable(),
                    planned: plannedCounts(for: sessions,
                                           rest: rest,
                                           maxHR: maxHR,
                                           confirmedWorkouts: confirmedWorkouts,
                                           confirmedSleeps: confirmedSleeps),
                    referenceAudit: referenceAuditDiagnostics(),
                    readback: readbackDiagnostics())
    }

    private enum ReferenceAuditDefaults {
        static let status = "atria.healthkit.referenceAudit.status"
        static let total = "atria.healthkit.referenceAudit.totalHRSamples"
        static let atria = "atria.healthkit.referenceAudit.atriaHRSamples"
        static let independentCandidate = "atria.healthkit.referenceAudit.independentCandidateHRSamples"
        static let userEntered = "atria.healthkit.referenceAudit.userEnteredHRSamples"
        static let rejectedUserEntered = "atria.healthkit.referenceAudit.rejectedUserEnteredHRSamples"
        static let independent = "atria.healthkit.referenceAudit.independentHRSamples"
        static let sources = "atria.healthkit.referenceAudit.independentSources"
        static let pairs = "atria.healthkit.referenceAudit.validationPairs"
        static let meanDelta = "atria.healthkit.referenceAudit.validationMeanDelta"
        static let maxDelta = "atria.healthkit.referenceAudit.validationMaxDelta"
        static let reason = "atria.healthkit.referenceAudit.validationReason"
        static let ready = "atria.healthkit.referenceAudit.externalReferenceReady"
    }

    nonisolated private static func recordReferenceAudit(status: String,
                                                         total: Int,
                                                         atria: Int,
                                                         independentCandidate: Int = 0,
                                                         userEntered: Int = 0,
                                                         rejectedUserEntered: Int = 0,
                                                         independent: Int,
                                                         sources: String,
                                                         validated: Bool = false,
                                                         pairs: Int = 0,
                                                         meanDelta: Double? = nil,
                                                         maxDelta: Double? = nil,
                                                         reason: String = "not_validated") {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: ReferenceAuditDefaults.status)
        defaults.set(total, forKey: ReferenceAuditDefaults.total)
        defaults.set(atria, forKey: ReferenceAuditDefaults.atria)
        defaults.set(independentCandidate, forKey: ReferenceAuditDefaults.independentCandidate)
        defaults.set(userEntered, forKey: ReferenceAuditDefaults.userEntered)
        defaults.set(rejectedUserEntered, forKey: ReferenceAuditDefaults.rejectedUserEntered)
        defaults.set(independent, forKey: ReferenceAuditDefaults.independent)
        defaults.set(sources, forKey: ReferenceAuditDefaults.sources)
        defaults.set(pairs, forKey: ReferenceAuditDefaults.pairs)
        defaults.set(reason, forKey: ReferenceAuditDefaults.reason)
        if let meanDelta {
            defaults.set(meanDelta, forKey: ReferenceAuditDefaults.meanDelta)
        } else {
            defaults.removeObject(forKey: ReferenceAuditDefaults.meanDelta)
        }
        if let maxDelta {
            defaults.set(maxDelta, forKey: ReferenceAuditDefaults.maxDelta)
        } else {
            defaults.removeObject(forKey: ReferenceAuditDefaults.maxDelta)
        }
        defaults.set(validated, forKey: ReferenceAuditDefaults.ready)
    }

    private static func referenceAuditDiagnostics() -> ReferenceAuditDiagnostics {
        let defaults = UserDefaults.standard
        let pairs = defaults.integer(forKey: ReferenceAuditDefaults.pairs)
        let meanDelta = defaults.object(forKey: ReferenceAuditDefaults.meanDelta) as? Double
        let maxDelta = defaults.object(forKey: ReferenceAuditDefaults.maxDelta) as? Double
        let reason = defaults.string(forKey: ReferenceAuditDefaults.reason) ?? "not_run"
        let validated = defaults.bool(forKey: ReferenceAuditDefaults.ready)
            && reason == "ready"
            && pairs >= 30
            && meanDelta.map { $0 <= 2 } == true
            && maxDelta.map { $0 <= 2 } == true
        return ReferenceAuditDiagnostics(
            status: defaults.string(forKey: ReferenceAuditDefaults.status) ?? "not_run",
            totalHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.total),
            atriaHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.atria),
            independentCandidateHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.independentCandidate),
            userEnteredHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.userEntered),
            rejectedUserEnteredHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.rejectedUserEntered),
            independentHRSamples: defaults.integer(forKey: ReferenceAuditDefaults.independent),
            independentSources: defaults.string(forKey: ReferenceAuditDefaults.sources) ?? "none",
            validationPairs: pairs,
            validationMeanDelta: meanDelta,
            validationMaxDelta: maxDelta,
            validationReason: reason,
            externalReferenceReady: validated
        )
    }

    private enum ReadbackDefaults {
        static let status = "atria.healthkit.readback.status"
        static let reason = "atria.healthkit.readback.reason"
        static let expectedDelta = "atria.healthkit.readback.expectedDeltaHRSamples"
        static let expectedTotal = "atria.healthkit.readback.expectedTotalAtriaHRSamples"
        static let readbackAtria = "atria.healthkit.readback.readbackAtriaHRSamples"
        static let total = "atria.healthkit.readback.totalHRSamples"
        static let dataAppears = "atria.healthkit.readback.dataAppears"
    }

    nonisolated private static func recordReadback(status: String,
                                                   reason: String,
                                                   expectedDeltaHRSamples: Int,
                                                   expectedTotalAtriaHRSamples: Int,
                                                   readbackAtriaHRSamples: Int,
                                                   totalHRSamples: Int,
                                                   dataAppears: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: ReadbackDefaults.status)
        defaults.set(reason, forKey: ReadbackDefaults.reason)
        defaults.set(expectedDeltaHRSamples, forKey: ReadbackDefaults.expectedDelta)
        defaults.set(expectedTotalAtriaHRSamples, forKey: ReadbackDefaults.expectedTotal)
        defaults.set(readbackAtriaHRSamples, forKey: ReadbackDefaults.readbackAtria)
        defaults.set(totalHRSamples, forKey: ReadbackDefaults.total)
        defaults.set(dataAppears, forKey: ReadbackDefaults.dataAppears)
    }

    private static func readbackDiagnostics() -> ReadbackDiagnostics {
        let defaults = UserDefaults.standard
        return ReadbackDiagnostics(status: defaults.string(forKey: ReadbackDefaults.status) ?? "not_run",
                                   reason: defaults.string(forKey: ReadbackDefaults.reason) ?? "not_run",
                                   expectedDeltaHRSamples: defaults.integer(forKey: ReadbackDefaults.expectedDelta),
                                   expectedTotalAtriaHRSamples: defaults.integer(forKey: ReadbackDefaults.expectedTotal),
                                   readbackAtriaHRSamples: defaults.integer(forKey: ReadbackDefaults.readbackAtria),
                                   totalHRSamples: defaults.integer(forKey: ReadbackDefaults.total),
                                   dataAppears: defaults.bool(forKey: ReadbackDefaults.dataAppears))
    }

    private static func plannedCounts(for sessions: [SavedSession],
                                      rest: Int,
                                      maxHR: Int,
                                      confirmedWorkouts: [UserConfirmedWorkout] = [],
                                      confirmedSleeps: [UserConfirmedSleep] = []) -> PlannedCounts {
        var hrSamples = 0
        var workouts = 0
        var hrvSamples = 0
        var sleeps = 0

        for session in sessions where session.end > session.start {
            hrSamples += Self.healthKitWritableHRPoints(for: session, exportedPointCount: 0)
            if session.workoutReadiness(rest: rest, maxHR: maxHR).ready {
                workouts += 1
            }
            if let hrv = session.referenceValidatedHRV, hrv > 0 {
                hrvSamples += 1
            }
        }
        workouts += confirmedWorkouts.count
        sleeps += confirmedSleeps.count

        return PlannedCounts(hrSamples: hrSamples, workouts: workouts, hrvSamples: hrvSamples, sleeps: sleeps)
    }

    private func plannedCounts(for sessions: [SavedSession],
                               confirmedWorkouts: [UserConfirmedWorkout],
                               confirmedSleeps: [UserConfirmedSleep],
                               ledger: ExportLedger,
                               rest: Int,
                               maxHR: Int) -> PlannedCounts {
        var hrSamples = 0
        var workouts = 0
        var hrvSamples = 0
        var sleeps = 0

        for session in sessions where session.end > session.start {
            let snapshot = ledger[session.id.uuidString]
            let exportedPointCount = min(snapshot?.hrPointCount ?? 0, session.points.count)
            hrSamples += Self.healthKitWritableHRPoints(for: session, exportedPointCount: exportedPointCount)
            if session.workoutReadiness(rest: rest, maxHR: maxHR).ready, snapshot?.workoutExported != true {
                workouts += 1
            }
            if let hrv = session.referenceValidatedHRV, hrv > 0, snapshot?.hrvExported != true {
                hrvSamples += 1
            }
        }
        for workout in confirmedWorkouts where ledger[Self.confirmedWorkoutLedgerKey(workout.id)]?.workoutExported != true {
            workouts += 1
        }
        for sleep in confirmedSleeps where ledger[Self.confirmedSleepLedgerKey(sleep.id)]?.workoutExported != true {
            sleeps += 1
        }

        return PlannedCounts(hrSamples: hrSamples, workouts: workouts, hrvSamples: hrvSamples, sleeps: sleeps)
    }

    nonisolated private static func healthKitWritableHRPoints(for session: SavedSession, exportedPointCount: Int) -> Int {
        session.points.dropFirst(exportedPointCount).filter { point in
            guard point.bpm > 0 else { return false }
            let start = session.start.addingTimeInterval(max(0, point.t))
            let end = start.addingTimeInterval(1)
            return min(end, session.end) > start
        }.count
    }

    nonisolated private static func expectedSessionIDs(for sessions: [SavedSession]) -> Set<String> {
        Set(sessions.map { $0.id.uuidString })
    }

    nonisolated private static func hrBackfillGaps(sessions: [SavedSession],
                                                   readbackBySessionID: [String: Int]) -> [HRBackfillGap] {
        sessions.compactMap { session -> HRBackfillGap? in
            guard session.end > session.start else { return nil }
            let expected = Self.healthKitWritableHRPoints(for: session, exportedPointCount: 0)
            guard expected > 0 else { return nil }
            let readback = readbackBySessionID[session.id.uuidString] ?? 0
            guard readback < expected else { return nil }
            return HRBackfillGap(session: session, expected: expected, readback: readback)
        }
    }

    private func repairMissingHeartRateBackfill(gaps: [HRBackfillGap],
                                                allSessions: [SavedSession],
                                                missingTotal: Int,
                                                rest: Int,
                                                maxHR: Int) {
        let repairGaps = Self.selectedBackfillRepairGaps(gaps: gaps, sampleBudget: missingTotal)
        let missingSessions = repairGaps.map(\.session)
        let missingSamples = repairGaps.reduce(0) { $0 + $1.missing }
        guard !missingSessions.isEmpty, missingSamples > 0 else { return }

        var repairLedger = loadExportLedger()
        for gap in repairGaps {
            let key = gap.session.id.uuidString
            let existing = repairLedger[key]
            repairLedger[key] = ExportSnapshot(hrPointCount: 0,
                                               hrvExported: existing?.hrvExported ?? true,
                                               workoutExported: existing?.workoutExported ?? true,
                                               end: gap.session.end.timeIntervalSince1970)
        }

        let sampleCap = missingSessions.reduce(0) {
            $0 + Self.healthKitWritableHRPoints(for: $1, exportedPointCount: 0)
        }
        NSLog("WHOOPDBG healthkit_backfill_repair status=started sessions=%d attributed_missing_hr_samples=%d global_missing_hr_samples=%d write_hr_sample_cap=%d candidate_sessions=%d metric_promotions=0 reason=readback_missing_atria_session_ids_capped_to_global_gap",
              missingSessions.count,
              missingSamples,
              missingTotal,
              sampleCap,
              gaps.count)
        writeAuthorizedSessions(missingSessions,
                                verificationSessions: allSessions,
                                rest: rest,
                                maxHR: maxHR,
                                ledger: repairLedger,
                                reason: "hr_backfill_repair",
                                hrOnly: true)
    }

    nonisolated private static func selectedBackfillRepairGaps(gaps: [HRBackfillGap], sampleBudget: Int) -> [HRBackfillGap] {
        guard sampleBudget > 0 else { return [] }
        let ordered = gaps.sorted {
            if $0.missing == $1.missing {
                return $0.session.start < $1.session.start
            }
            return $0.missing < $1.missing
        }
        var selected: [HRBackfillGap] = []
        var total = 0
        for gap in ordered {
            if total + gap.missing > sampleBudget, !selected.isEmpty {
                break
            }
            selected.append(gap)
            total += gap.missing
            if total >= sampleBudget { break }
        }
        return selected
    }

    private func loadExportLedger() -> ExportLedger {
        guard let data = UserDefaults.standard.data(forKey: ExportLedgerDefaults.key),
              let ledger = try? JSONDecoder().decode(ExportLedger.self, from: data) else {
            return [:]
        }
        return ledger
    }

    private func saveExportLedger(_ ledger: ExportLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        UserDefaults.standard.set(data, forKey: ExportLedgerDefaults.key)
    }

    private static func confirmedWorkoutLedgerKey(_ id: String) -> String {
        "confirmed_workout:\(id)"
    }

    private static func confirmedSleepLedgerKey(_ id: String) -> String {
        "confirmed_sleep:\(id)"
    }

    private func markSessionsExported(_ sessions: [SavedSession],
                                      confirmedWorkouts: [UserConfirmedWorkout],
                                      confirmedSleeps: [UserConfirmedSleep],
                                      rest: Int,
                                      maxHR: Int,
                                      ledger: inout ExportLedger) {
        for session in sessions where session.end > session.start {
            let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)
            ledger[session.id.uuidString] = ExportSnapshot(
                hrPointCount: session.points.count,
                hrvExported: (session.referenceValidatedHRV ?? 0) > 0,
                workoutExported: readiness.ready,
                end: session.end.timeIntervalSince1970
            )
        }
        for workout in confirmedWorkouts {
            ledger[Self.confirmedWorkoutLedgerKey(workout.id)] = ExportSnapshot(
                hrPointCount: 0,
                hrvExported: true,
                workoutExported: true,
                end: workout.end.timeIntervalSince1970
            )
        }
        for sleep in confirmedSleeps {
            ledger[Self.confirmedSleepLedgerKey(sleep.id)] = ExportSnapshot(
                hrPointCount: 0,
                hrvExported: true,
                workoutExported: true,
                end: sleep.end.timeIntervalSince1970
            )
        }
    }

    private func markSessionsHeartRateExported(_ sessions: [SavedSession], ledger: inout ExportLedger) {
        for session in sessions where session.end > session.start {
            let existing = ledger[session.id.uuidString]
            ledger[session.id.uuidString] = ExportSnapshot(
                hrPointCount: session.points.count,
                hrvExported: existing?.hrvExported ?? false,
                workoutExported: existing?.workoutExported ?? false,
                end: session.end.timeIntervalSince1970
            )
        }
    }

    private func writeAuthorizedSessions(_ sessions: [SavedSession],
                                         confirmedWorkouts: [UserConfirmedWorkout] = [],
                                         confirmedSleeps: [UserConfirmedSleep] = [],
                                         verificationSessions: [SavedSession],
                                         rest: Int,
                                         maxHR: Int,
                                         ledger: ExportLedger,
                                         reason: String,
                                         hrOnly: Bool) {
        var updatedLedger = ledger
        var samples: [HKSample] = sessions.flatMap { session -> [HKSample] in
            let snapshot = ledger[session.id.uuidString]
            if hrOnly {
                return heartRateSamples(for: session, snapshot: snapshot)
            }
            return healthSamples(for: session,
                                 rest: rest,
                                 maxHR: maxHR,
                                 snapshot: snapshot)
        }
        if !hrOnly {
            samples.append(contentsOf: confirmedWorkouts.compactMap { workout in
                let key = Self.confirmedWorkoutLedgerKey(workout.id)
                guard ledger[key]?.workoutExported != true else { return nil }
                return confirmedWorkoutSample(for: workout)
            })
            samples.append(contentsOf: confirmedSleeps.compactMap { sleep in
                let key = Self.confirmedSleepLedgerKey(sleep.id)
                guard ledger[key]?.workoutExported != true else { return nil }
                return confirmedSleepSample(for: sleep)
            })
        }
        guard !samples.isEmpty else {
            NSLog("WHOOPDBG healthkit_export status=up_to_date sessions=%d hr_samples=0 workouts=0 hrv_samples=0 sleeps=0 ledger_entries=%d idempotent=1 reason=%@",
                  sessions.count,
                  ledger.count,
                  reason)
            return
        }

        let hrSamples = samples.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType == heartRateType }
            .count
        let hrvSamples = samples.compactMap { $0 as? HKQuantitySample }
            .filter { $0.quantityType == hrvType }
            .count
        let workouts = samples.compactMap { $0 as? HKWorkout }.count
        let sleeps = samples.compactMap { $0 as? HKCategorySample }
            .filter { $0.categoryType == sleepType }
            .count

        store.save(samples) { [weak self] success, error in
            if let error {
                NSLog("WHOOPDBG healthkit_export status=save_error sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d ledger_entries=%d reason=%@ error=%@",
                      sessions.count,
                      hrSamples,
                      workouts,
                      hrvSamples,
                      sleeps,
                      ledger.count,
                      reason,
                      String(describing: error))
                return
            }
            guard success else {
                NSLog("WHOOPDBG healthkit_export status=failed sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d ledger_entries=%d idempotent=1 incremental=1 reason=%@",
                      sessions.count,
                      hrSamples,
                      workouts,
                      hrvSamples,
                      sleeps,
                      updatedLedger.count,
                      reason)
                return
            }
            Task { @MainActor in
                guard let self else { return }
                if hrOnly {
                    self.markSessionsHeartRateExported(sessions, ledger: &updatedLedger)
                } else {
                    self.markSessionsExported(sessions,
                                              confirmedWorkouts: confirmedWorkouts,
                                              confirmedSleeps: confirmedSleeps,
                                              rest: rest,
                                              maxHR: maxHR,
                                              ledger: &updatedLedger)
                }
                self.saveExportLedger(updatedLedger)
                NSLog("WHOOPDBG healthkit_export status=saved sessions=%d hr_samples=%d workouts=%d hrv_samples=%d sleeps=%d ledger_entries=%d idempotent=1 incremental=1 reason=%@",
                      sessions.count,
                      hrSamples,
                      workouts,
                      hrvSamples,
                      sleeps,
                      updatedLedger.count,
                      reason)
                self.verifyHeartRateExportReadback(sessions: sessions,
                                                   verificationSessions: verificationSessions,
                                                   expectedDeltaHRSamples: hrSamples,
                                                   expectedTotalAtriaHRSamples: Self.plannedCounts(for: verificationSessions,
                                                                                                  rest: rest,
                                                                                                  maxHR: maxHR,
                                                                                                  confirmedWorkouts: [],
                                                                                                  confirmedSleeps: []).hrSamples,
                                                   rest: rest,
                                                   maxHR: maxHR,
                                                   reason: reason)
                self.verifySleepExportReadback(confirmedSleeps: confirmedSleeps,
                                               expectedDeltaSleeps: sleeps,
                                               reason: reason)
                if reason == "hr_reset_rebuild" {
                    NSLog("WHOOPDBG healthkit_reset_rebuild status=complete sessions=%d rebuilt_hr_samples=%d metric_promotions=0",
                          sessions.count,
                          hrSamples)
                }
            }
        }
    }

    private func verifyHeartRateExportReadback(sessions: [SavedSession],
                                               verificationSessions: [SavedSession]? = nil,
                                               expectedDeltaHRSamples: Int,
                                               expectedTotalAtriaHRSamples: Int,
                                               rest: Int,
                                               maxHR: Int,
                                               reason: String) {
        let readbackSessions = verificationSessions ?? sessions
        guard expectedDeltaHRSamples > 0 || expectedTotalAtriaHRSamples > 0 else {
            NSLog("WHOOPDBG healthkit_export_verify status=skipped reason=%@ expected_delta_hr_samples=0 expected_total_atria_hr_samples=0 readback_atria_hr_samples=0 data_appears=0",
                  reason)
            Self.recordReadback(status: "skipped",
                                reason: reason,
                                expectedDeltaHRSamples: 0,
                                expectedTotalAtriaHRSamples: 0,
                                readbackAtriaHRSamples: 0,
                                totalHRSamples: 0,
                                dataAppears: false)
            return
        }
        guard let start = readbackSessions.map(\.start).min(),
              let end = readbackSessions.map(\.end).max(),
              end > start else {
            NSLog("WHOOPDBG healthkit_export_verify status=no_session_window reason=%@ expected_delta_hr_samples=%d expected_total_atria_hr_samples=%d readback_atria_hr_samples=0 data_appears=0",
                  reason,
                  expectedDeltaHRSamples,
                  expectedTotalAtriaHRSamples)
            Self.recordReadback(status: "no_session_window",
                                reason: reason,
                                expectedDeltaHRSamples: expectedDeltaHRSamples,
                                expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                readbackAtriaHRSamples: 0,
                                totalHRSamples: 0,
                                dataAppears: false)
            return
        }

        store.getRequestStatusForAuthorization(toShare: [], read: [heartRateType]) { [weak self] status, error in
            guard let self else { return }
            if let error {
                NSLog("WHOOPDBG healthkit_export_verify status=request_status_error reason=%@ expected_delta_hr_samples=%d expected_total_atria_hr_samples=%d readback_atria_hr_samples=0 data_appears=0 error=%@",
                      reason,
                      expectedDeltaHRSamples,
                      expectedTotalAtriaHRSamples,
                      String(describing: error))
                Self.recordReadback(status: "request_status_error",
                                    reason: reason,
                                    expectedDeltaHRSamples: expectedDeltaHRSamples,
                                    expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                    readbackAtriaHRSamples: 0,
                                    totalHRSamples: 0,
                                    dataAppears: false)
                return
            }
            guard status == .unnecessary else {
                NSLog("WHOOPDBG healthkit_export_verify status=read_permission_required reason=%@ request_status=%@ expected_delta_hr_samples=%d expected_total_atria_hr_samples=%d readback_atria_hr_samples=0 data_appears=0 action=grant_health_read_heart_rate",
                      reason,
                      Self.requestStatusLabel(status),
                      expectedDeltaHRSamples,
                      expectedTotalAtriaHRSamples)
                Self.recordReadback(status: "read_permission_required",
                                    reason: reason,
                                    expectedDeltaHRSamples: expectedDeltaHRSamples,
                                    expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                    readbackAtriaHRSamples: 0,
                                    totalHRSamples: 0,
                                    dataAppears: false)
                return
            }
            Task { @MainActor in
                self.queryHeartRateExportReadback(start: start,
                                                  end: end,
                                                  sessions: readbackSessions,
                                                  expectedDeltaHRSamples: expectedDeltaHRSamples,
                                                  expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                                  rest: rest,
                                                  maxHR: maxHR,
                                                  reason: reason)
            }
        }
    }

    private func verifySleepExportReadback(confirmedSleeps: [UserConfirmedSleep],
                                           expectedDeltaSleeps: Int,
                                           reason: String) {
        guard expectedDeltaSleeps > 0 else {
            if !confirmedSleeps.isEmpty {
                NSLog("WHOOPDBG healthkit_sleep_export_verify status=skipped reason=%@ expected_delta_sleeps=0 confirmed_sleeps=%d data_appears=0",
                      reason,
                      confirmedSleeps.count)
            }
            return
        }
        guard let start = confirmedSleeps.map(\.start).min(),
              let end = confirmedSleeps.map(\.end).max(),
              end > start else {
            NSLog("WHOOPDBG healthkit_sleep_export_verify status=no_sleep_window reason=%@ expected_delta_sleeps=%d readback_sleeps=0 data_appears=0",
                  reason,
                  expectedDeltaSleeps)
            return
        }

        store.getRequestStatusForAuthorization(toShare: [], read: [sleepType]) { [weak self] status, error in
            guard let self else { return }
            if let error {
                NSLog("WHOOPDBG healthkit_sleep_export_verify status=request_status_error reason=%@ expected_delta_sleeps=%d readback_sleeps=0 data_appears=0 error=%@",
                      reason,
                      expectedDeltaSleeps,
                      String(describing: error))
                return
            }
            guard status == .unnecessary else {
                NSLog("WHOOPDBG healthkit_sleep_export_verify status=read_permission_required reason=%@ request_status=%@ expected_delta_sleeps=%d readback_sleeps=0 data_appears=0 action=grant_health_read_sleep",
                      reason,
                      Self.requestStatusLabel(status),
                      expectedDeltaSleeps)
                return
            }
            Task { @MainActor in
                self.querySleepExportReadback(start: start,
                                              end: end,
                                              confirmedSleeps: confirmedSleeps,
                                              expectedDeltaSleeps: expectedDeltaSleeps,
                                              reason: reason)
            }
        }
    }

    private func querySleepExportReadback(start: Date,
                                          end: Date,
                                          confirmedSleeps: [UserConfirmedSleep],
                                          expectedDeltaSleeps: Int,
                                          reason: String) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: sleepType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
            if let error {
                NSLog("WHOOPDBG healthkit_sleep_export_verify status=query_error reason=%@ expected_delta_sleeps=%d readback_sleeps=0 data_appears=0 error=%@",
                      reason,
                      expectedDeltaSleeps,
                      String(describing: error))
                return
            }
            let categorySamples = samples as? [HKCategorySample] ?? []
            let expectedIDs = Set(confirmedSleeps.map(\.id))
            var scoped = 0
            var broad = 0
            for sample in categorySamples {
                if sample.metadata?["atria_sleep_id"] != nil {
                    broad += 1
                }
                guard let id = sample.metadata?["atria_sleep_id"] as? String,
                      expectedIDs.contains(id) else {
                    continue
                }
                scoped += 1
            }
            let dataAppears = scoped >= expectedDeltaSleeps
            NSLog("WHOOPDBG healthkit_sleep_export_verify status=%@ reason=%@ expected_delta_sleeps=%d readback_sleeps=%d broad_atria_sleeps=%d total_sleep_samples=%d data_appears=%d scope=atria_sleep_id source=healthkit_read note=user_confirmed_sleep_not_auto_gate_e",
                  dataAppears ? "ok" : "short",
                  reason,
                  expectedDeltaSleeps,
                  scoped,
                  broad,
                  categorySamples.count,
                  dataAppears ? 1 : 0)
        }
        store.execute(query)
    }

    private func queryHeartRateExportReadback(start: Date,
                                              end: Date,
                                              sessions: [SavedSession],
                                              expectedDeltaHRSamples: Int,
                                              expectedTotalAtriaHRSamples: Int,
                                              rest: Int,
                                              maxHR: Int,
                                              reason: String) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: heartRateType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
            if let error {
                NSLog("WHOOPDBG healthkit_export_verify status=query_error reason=%@ expected_delta_hr_samples=%d expected_total_atria_hr_samples=%d readback_atria_hr_samples=0 data_appears=0 error=%@",
                      reason,
                      expectedDeltaHRSamples,
                      expectedTotalAtriaHRSamples,
                      String(describing: error))
                Self.recordReadback(status: "query_error",
                                    reason: reason,
                                    expectedDeltaHRSamples: expectedDeltaHRSamples,
                                    expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                    readbackAtriaHRSamples: 0,
                                    totalHRSamples: 0,
                                    dataAppears: false)
                return
            }
            let quantitySamples = samples as? [HKQuantitySample] ?? []
            let appBundle = Bundle.main.bundleIdentifier ?? "unknown"
            let expectedSessionIDs = Self.expectedSessionIDs(for: sessions)
            var readbackBySessionID: [String: Int] = [:]
            var broadAtriaSamples = 0
            var scopedAtriaSamples = 0
            for sample in quantitySamples {
                let isAtria = sample.sourceRevision.source.bundleIdentifier == appBundle ||
                    sample.metadata?["atria_session_id"] != nil
                if isAtria {
                    broadAtriaSamples += 1
                }
                guard let sessionID = sample.metadata?["atria_session_id"] as? String,
                      expectedSessionIDs.contains(sessionID) else {
                    continue
                }
                scopedAtriaSamples += 1
                if isAtria {
                    readbackBySessionID[sessionID, default: 0] += 1
                }
            }
            let readbackCoversDelta = expectedDeltaHRSamples == 0 || scopedAtriaSamples >= expectedDeltaHRSamples
            let expectedTotalCovered = expectedTotalAtriaHRSamples > 0 && scopedAtriaSamples >= expectedTotalAtriaHRSamples
            let expectedTotalReconciled = expectedTotalAtriaHRSamples > 0 && scopedAtriaSamples == expectedTotalAtriaHRSamples
            let missingTotal = max(expectedTotalAtriaHRSamples - scopedAtriaSamples, 0)
            let overfillTotal = max(scopedAtriaSamples - expectedTotalAtriaHRSamples, 0)
            let backfillGaps = Self.hrBackfillGaps(sessions: sessions, readbackBySessionID: readbackBySessionID)
            let missingSessions = backfillGaps.count
            let missingAttributedSamples = backfillGaps.reduce(0) { $0 + $1.missing }
            let dataAppears = scopedAtriaSamples > 0 && readbackCoversDelta
            let reconciliationStatus = overfillTotal > 0
                ? "overfilled"
                : (expectedTotalReconciled ? "reconciled" : "legacy_backfill_pending")
            NSLog("WHOOPDBG healthkit_export_verify status=%@ reason=%@ expected_delta_hr_samples=%d expected_total_atria_hr_samples=%d readback_atria_hr_samples=%d broad_atria_hr_samples=%d scoped_atria_hr_samples=%d expected_session_ids=%d missing_total_atria_hr_samples=%d overfill_total_atria_hr_samples=%d missing_attributed_sessions=%d missing_attributed_hr_samples=%d total_hr_samples=%d readback_covers_delta=%d expected_total_covered=%d expected_total_reconciled=%d reconciliation=%@ data_appears=%d scope=session_metadata source=healthkit_read note=atria_samples_not_external_reference",
                  dataAppears ? "ok" : "short",
                  reason,
                  expectedDeltaHRSamples,
                  expectedTotalAtriaHRSamples,
                  scopedAtriaSamples,
                  broadAtriaSamples,
                  scopedAtriaSamples,
                  expectedSessionIDs.count,
                  missingTotal,
                  overfillTotal,
                  missingSessions,
                  missingAttributedSamples,
                  quantitySamples.count,
                  readbackCoversDelta ? 1 : 0,
                  expectedTotalCovered ? 1 : 0,
                  expectedTotalReconciled ? 1 : 0,
                  reconciliationStatus,
                  dataAppears ? 1 : 0)
            Self.recordReadback(status: dataAppears ? "ok" : "short",
                                reason: reason,
                                expectedDeltaHRSamples: expectedDeltaHRSamples,
                                expectedTotalAtriaHRSamples: expectedTotalAtriaHRSamples,
                                readbackAtriaHRSamples: scopedAtriaSamples,
                                totalHRSamples: quantitySamples.count,
                                dataAppears: dataAppears)
            if !expectedTotalCovered && reason != "hr_backfill_repair" && !backfillGaps.isEmpty {
                Task { @MainActor in
                    self.repairMissingHeartRateBackfill(gaps: backfillGaps,
                                                        allSessions: sessions,
                                                        missingTotal: missingTotal,
                                                        rest: rest,
                                                        maxHR: maxHR)
                }
            }
        }
        store.execute(query)
    }

    private func resetAndRebuildAtriaHeartRate(sessions: [SavedSession], rest: Int, maxHR: Int) {
        let planned = Self.plannedCounts(for: sessions, rest: rest, maxHR: maxHR)
        guard Self.hasHealthKitEntitlement() else {
            NSLog("WHOOPDBG healthkit_reset_rebuild status=missing_entitlement sessions=%d expected_hr_samples=%d action=enable_healthkit_capability",
                  sessions.count,
                  planned.hrSamples)
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            NSLog("WHOOPDBG healthkit_reset_rebuild status=unavailable sessions=%d expected_hr_samples=%d",
                  sessions.count,
                  planned.hrSamples)
            return
        }
        guard planned.hrSamples > 0,
              let start = sessions.map(\.start).min(),
              let end = sessions.map(\.end).max(),
              end > start else {
            NSLog("WHOOPDBG healthkit_reset_rebuild status=no_session_window sessions=%d expected_hr_samples=%d",
                  sessions.count,
                  planned.hrSamples)
            return
        }

        NSLog("WHOOPDBG healthkit_reset_rebuild status=authorization_requested sessions=%d expected_hr_samples=%d scope=atria_heart_rate_only",
              sessions.count,
              planned.hrSamples)
        store.requestAuthorization(toShare: [heartRateType], read: [heartRateType]) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    NSLog("WHOOPDBG healthkit_reset_rebuild status=auth_error sessions=%d expected_hr_samples=%d error=%@",
                          sessions.count,
                          planned.hrSamples,
                          String(describing: error))
                    return
                }
                guard success else {
                    NSLog("WHOOPDBG healthkit_reset_rebuild status=auth_denied sessions=%d expected_hr_samples=%d action=grant_health_write_permissions",
                          sessions.count,
                          planned.hrSamples)
                    return
                }
                self.deleteAndRebuildAtriaHeartRate(sessions: sessions,
                                                    rest: rest,
                                                    maxHR: maxHR,
                                                    expectedHRSamples: planned.hrSamples,
                                                    start: start,
                                                    end: end)
            }
        }
    }

    private func deleteAndRebuildAtriaHeartRate(sessions: [SavedSession],
                                                rest: Int,
                                                maxHR: Int,
                                                expectedHRSamples: Int,
                                                start: Date,
                                                end: Date) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let query = HKSampleQuery(sampleType: heartRateType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { [weak self] _, samples, error in
            guard let self else { return }
            if let error {
                NSLog("WHOOPDBG healthkit_reset_rebuild status=query_error sessions=%d expected_hr_samples=%d error=%@",
                      sessions.count,
                      expectedHRSamples,
                      String(describing: error))
                return
            }
            let quantitySamples = samples as? [HKQuantitySample] ?? []
            let appBundle = Bundle.main.bundleIdentifier ?? "unknown"
            let expectedSessionIDs = Self.expectedSessionIDs(for: sessions)
            let broadAtriaSamples = quantitySamples.filter { sample in
                sample.sourceRevision.source.bundleIdentifier == appBundle || sample.metadata?["atria_session_id"] != nil
            }
            let atriaSamples = broadAtriaSamples.filter { sample in
                guard let sessionID = sample.metadata?["atria_session_id"] as? String else { return false }
                return expectedSessionIDs.contains(sessionID)
            }
            let independentSamples = quantitySamples.count - broadAtriaSamples.count
            let preservedAtriaSamples = broadAtriaSamples.count - atriaSamples.count
            NSLog("WHOOPDBG healthkit_reset_rebuild status=delete_selected sessions=%d expected_hr_samples=%d total_hr_samples=%d atria_hr_samples=%d broad_atria_hr_samples=%d preserved_atria_hr_samples=%d independent_hr_samples=%d expected_session_ids=%d scope=session_metadata",
                  sessions.count,
                  expectedHRSamples,
                  quantitySamples.count,
                  atriaSamples.count,
                  broadAtriaSamples.count,
                  preservedAtriaSamples,
                  independentSamples)
            guard !atriaSamples.isEmpty else {
                Task { @MainActor in
                    self.rebuildAtriaHeartRate(sessions: sessions,
                                               rest: rest,
                                               maxHR: maxHR,
                                               expectedHRSamples: expectedHRSamples,
                                               deletedHRSamples: 0)
                }
                return
            }
            self.store.delete(atriaSamples) { success, error in
                Task { @MainActor in
                    if let error {
                        NSLog("WHOOPDBG healthkit_reset_rebuild status=delete_error sessions=%d expected_hr_samples=%d selected_hr_samples=%d error=%@",
                              sessions.count,
                              expectedHRSamples,
                              atriaSamples.count,
                              String(describing: error))
                        return
                    }
                    guard success else {
                        NSLog("WHOOPDBG healthkit_reset_rebuild status=delete_failed sessions=%d expected_hr_samples=%d selected_hr_samples=%d",
                              sessions.count,
                              expectedHRSamples,
                              atriaSamples.count)
                        return
                    }
                    NSLog("WHOOPDBG healthkit_reset_rebuild status=deleted sessions=%d expected_hr_samples=%d deleted_hr_samples=%d independent_hr_samples_preserved=%d",
                          sessions.count,
                          expectedHRSamples,
                          atriaSamples.count,
                          independentSamples)
                    self.rebuildAtriaHeartRate(sessions: sessions,
                                               rest: rest,
                                               maxHR: maxHR,
                                               expectedHRSamples: expectedHRSamples,
                                               deletedHRSamples: atriaSamples.count)
                }
            }
        }
        store.execute(query)
    }

    private func rebuildAtriaHeartRate(sessions: [SavedSession],
                                       rest: Int,
                                       maxHR: Int,
                                       expectedHRSamples: Int,
                                       deletedHRSamples: Int) {
        var rebuildLedger = loadExportLedger()
        for session in sessions where session.end > session.start {
            let key = session.id.uuidString
            let existing = rebuildLedger[key]
            rebuildLedger[key] = ExportSnapshot(hrPointCount: 0,
                                                hrvExported: existing?.hrvExported ?? false,
                                                workoutExported: existing?.workoutExported ?? false,
                                                end: session.end.timeIntervalSince1970)
        }
        NSLog("WHOOPDBG healthkit_reset_rebuild status=rebuild_started sessions=%d expected_hr_samples=%d deleted_hr_samples=%d metric_promotions=0 reason=atria_hr_overfill_cleanup",
              sessions.count,
              expectedHRSamples,
              deletedHRSamples)
        writeAuthorizedSessions(sessions,
                                verificationSessions: sessions,
                                rest: rest,
                                maxHR: maxHR,
                                ledger: rebuildLedger,
                                reason: "hr_reset_rebuild",
                                hrOnly: true)
    }

    private func auditHeartRateReferenceAvailability(sessions: [SavedSession]) {
        guard let start = sessions.map(\.start).min(),
              let end = sessions.map(\.end).max(),
              end > start else {
            NSLog("WHOOPDBG healthkit_reference_audit status=no_session_window external_reference_ready=0 source=healthkit_read")
            Self.recordReferenceAudit(status: "no_session_window",
                                      total: 0,
                                      atria: 0,
                                      independent: 0,
                                      sources: "none")
            return
        }

        store.getRequestStatusForAuthorization(toShare: [], read: [heartRateType]) { [weak self] status, error in
            guard let self else { return }
            if let error {
                NSLog("WHOOPDBG healthkit_reference_audit status=request_status_error external_reference_ready=0 error=%@",
                      String(describing: error))
                Self.recordReferenceAudit(status: "request_status_error",
                                          total: 0,
                                          atria: 0,
                                          independent: 0,
                                          sources: "none")
                return
            }
            guard status == .unnecessary else {
                NSLog("WHOOPDBG healthkit_reference_audit status=read_permission_required request_status=%@ external_reference_ready=0 source=healthkit_read action=grant_health_read_heart_rate",
                      Self.requestStatusLabel(status))
                Self.recordReferenceAudit(status: "read_permission_required",
                                          total: 0,
                                          atria: 0,
                                          independent: 0,
                                          sources: "none")
                return
            }
            Task { @MainActor in
                self.queryHeartRateReferenceSamples(start: start, end: end, sessions: sessions)
            }
        }
    }

    private func queryHeartRateReferenceSamples(start: Date, end: Date, sessions: [SavedSession]) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: heartRateType,
                                  predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, samples, error in
            if let error {
                NSLog("WHOOPDBG healthkit_reference_audit status=query_error external_reference_ready=0 error=%@",
                      String(describing: error))
                Self.recordReferenceAudit(status: "query_error",
                                          total: 0,
                                          atria: 0,
                                          independent: 0,
                                          sources: "none")
                return
            }
            let quantitySamples = samples as? [HKQuantitySample] ?? []
            let appBundle = Bundle.main.bundleIdentifier ?? "unknown"
            var atriaSamples = 0
            var independentCandidateSamples = 0
            var userEnteredSamples = 0
            var rejectedUserEnteredSamples = 0
            var independentSamples: [HRReferencePoint] = []
            var sourceBundles: Set<String> = []
            for sample in quantitySamples {
                let bundle = sample.sourceRevision.source.bundleIdentifier
                let isAtriaMetadata = sample.metadata?["atria_session_id"] != nil
                if bundle == appBundle || isAtriaMetadata {
                    atriaSamples += 1
                } else {
                    independentCandidateSamples += 1
                    if Self.isUserEntered(sample) {
                        userEnteredSamples += 1
                        rejectedUserEnteredSamples += 1
                        continue
                    }
                    let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    if bpm > 0 {
                        independentSamples.append(HRReferencePoint(t: sample.startDate.timeIntervalSince1970,
                                                                   bpm: bpm))
                    }
                    sourceBundles.insert(bundle)
                }
            }
            let atriaReference = Self.savedHeartRateReferencePoints(from: sessions)
            let comparison = Self.compareHRReference(whoop: atriaReference,
                                                     reference: independentSamples,
                                                     toleranceBPM: 2,
                                                     maxPairAge: 5)
            let validationReason = independentSamples.isEmpty ? "independent_reference_missing" : comparison.reason
            let sourceList = sourceBundles.sorted().prefix(5).joined(separator: ",")
            NSLog("WHOOPDBG healthkit_reference_audit status=ok total_hr_samples=%d atria_hr_samples=%d independent_candidate_hr_samples=%d user_entered_hr_samples=%d rejected_user_entered_hr_samples=%d independent_hr_samples=%d independent_sources=%@ window_s=%.0f pairs=%d duration_s=%.0f mean_delta_bpm=%.2f median_delta_bpm=%.2f max_delta_bpm=%.2f within_tolerance_percent=%d tolerance_bpm=2 max_pair_age_s=5 independent_reference_present=%d reference_validated=%d external_reference_ready=%d validation_reason=%@ source=healthkit_read",
                  quantitySamples.count,
                  atriaSamples,
                  independentCandidateSamples,
                  userEnteredSamples,
                  rejectedUserEnteredSamples,
                  independentSamples.count,
                  sourceList.isEmpty ? "none" : sourceList,
                  end.timeIntervalSince(start),
                  comparison.pairs,
                  comparison.duration,
                  comparison.meanDelta ?? -1,
                  comparison.medianDelta ?? -1,
                  comparison.maxDelta ?? -1,
                  comparison.withinTolerancePercent,
                  independentSamples.isEmpty ? 0 : 1,
                  comparison.ready ? 1 : 0,
                  comparison.ready ? 1 : 0,
                  validationReason)
            Self.recordReferenceAudit(status: "ok",
                                      total: quantitySamples.count,
                                      atria: atriaSamples,
                                      independentCandidate: independentCandidateSamples,
                                      userEntered: userEnteredSamples,
                                      rejectedUserEntered: rejectedUserEnteredSamples,
                                      independent: independentSamples.count,
                                      sources: sourceList.isEmpty ? "none" : sourceList,
                                      validated: comparison.ready,
                                      pairs: comparison.pairs,
                                      meanDelta: comparison.meanDelta,
                                      maxDelta: comparison.maxDelta,
                                      reason: validationReason)
        }
        store.execute(query)
    }

    nonisolated private static func isUserEntered(_ sample: HKQuantitySample) -> Bool {
        guard let value = sample.metadata?[HKMetadataKeyWasUserEntered] else { return false }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let bool = value as? Bool {
            return bool
        }
        return false
    }

    nonisolated private static func savedHeartRateReferencePoints(from sessions: [SavedSession]) -> [HRReferencePoint] {
        sessions.flatMap { session in
            session.points.compactMap { point in
                guard point.bpm > 0 else { return nil }
                return HRReferencePoint(t: session.start.addingTimeInterval(max(0, point.t)).timeIntervalSince1970,
                                        bpm: Double(point.bpm))
            }
        }.sorted { $0.t < $1.t }
    }

    nonisolated private static func compareHRReference(whoop: [HRReferencePoint],
                                                       reference: [HRReferencePoint],
                                                       toleranceBPM: Double,
                                                       maxPairAge: TimeInterval) -> HRReferenceComparison {
        let paired = pairHRSamples(whoop: whoop, reference: reference, maxAge: maxPairAge)
        let deltas = paired.map { abs($0.whoop.bpm - $0.reference.bpm) }
        let duration = pairedDuration(paired)
        let meanDelta = deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count)
        let medianDelta = median(deltas)
        let maxDelta = deltas.max()
        let withinTolerance = deltas.filter { $0 <= toleranceBPM }.count
        let withinPercent = deltas.isEmpty ? 0 : Int((Double(withinTolerance) / Double(deltas.count) * 100).rounded())
        let ready = paired.count >= 30
            && duration >= 60
            && meanDelta.map { $0 <= toleranceBPM } == true
            && maxDelta.map { $0 <= toleranceBPM } == true
        let reason: String
        if paired.count < 30 { reason = "insufficient_pairs" }
        else if duration < 60 { reason = "window_too_short" }
        else if meanDelta == nil || maxDelta == nil { reason = "missing_metrics" }
        else if meanDelta! > toleranceBPM { reason = "mean_delta_over_tolerance" }
        else if maxDelta! > toleranceBPM { reason = "max_delta_over_tolerance" }
        else { reason = "ready" }
        return HRReferenceComparison(pairs: paired.count,
                                     duration: duration,
                                     meanDelta: meanDelta,
                                     medianDelta: medianDelta,
                                     maxDelta: maxDelta,
                                     withinTolerancePercent: withinPercent,
                                     ready: ready,
                                     reason: reason)
    }

    nonisolated private static func pairHRSamples(whoop: [HRReferencePoint],
                                                  reference: [HRReferencePoint],
                                                  maxAge: TimeInterval) -> [(whoop: HRReferencePoint, reference: HRReferencePoint)] {
        let refs = reference.sorted { $0.t < $1.t }
        guard !refs.isEmpty else { return [] }
        return whoop.sorted { $0.t < $1.t }.compactMap { sample in
            var best: HRReferencePoint?
            var bestDelta = maxAge
            for candidate in refs {
                let delta = abs(candidate.t - sample.t)
                if delta <= bestDelta {
                    best = candidate
                    bestDelta = delta
                } else if candidate.t > sample.t && delta > bestDelta {
                    break
                }
            }
            guard let best else { return nil }
            return (sample, best)
        }
    }

    nonisolated private static func pairedDuration(_ pairs: [(whoop: HRReferencePoint, reference: HRReferencePoint)]) -> TimeInterval {
        guard let first = pairs.first?.whoop.t,
              let last = pairs.last?.whoop.t else { return 0 }
        return max(0, last - first)
    }

    nonisolated private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let ordered = values.sorted()
        let middle = ordered.count / 2
        if ordered.count.isMultiple(of: 2) {
            return (ordered[middle - 1] + ordered[middle]) / 2
        }
        return ordered[middle]
    }

    private func healthSamples(for session: SavedSession,
                               rest: Int,
                               maxHR: Int,
                               snapshot: ExportSnapshot?) -> [HKSample] {
        guard session.end > session.start else { return [] }

        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: false,
            "atria_session_id": session.id.uuidString,
            "atria_label": session.label
        ]
        var samples = heartRateSamples(for: session, snapshot: snapshot)

        if snapshot?.hrvExported != true, let hrv = session.referenceValidatedHRV, hrv > 0 {
            let quantity = HKQuantity(unit: .secondUnit(with: .milli),
                                      doubleValue: Double(hrv))
            samples.append(HKQuantitySample(type: hrvType,
                                            quantity: quantity,
                                            start: session.start,
                                            end: session.end,
                                            metadata: metadata))
        }

        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)
        if readiness.ready, snapshot?.workoutExported != true {
            var workoutMetadata = metadata
            workoutMetadata["atria_workout_detector"] = "hrr50"
            workoutMetadata["atria_workout_confidence"] = "ready"
            workoutMetadata["atria_workout_threshold_hr"] = readiness.thresholdHR
            workoutMetadata["atria_workout_stream_coverage_percent"] = readiness.streamCoveragePercent
            let workout = HKWorkout(activityType: .other,
                                    start: session.start,
                                    end: session.end,
                                    duration: session.duration,
                                    totalEnergyBurned: nil,
                                    totalDistance: nil,
                                    metadata: workoutMetadata)
            samples.append(workout)
        }
        return samples
    }

    private func confirmedWorkoutSample(for workout: UserConfirmedWorkout) -> HKWorkout? {
        guard workout.end > workout.start else { return nil }
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: false,
            "atria_workout_id": workout.id,
            "atria_workout_source": "user_confirmed",
            "atria_workout_candidate_source": workout.source,
            "atria_workout_confidence": workout.confidence,
            "atria_workout_label": workout.label,
            "atria_workout_stream_coverage_percent": workout.streamCoveragePercent,
            "atria_workout_threshold_hr": workout.thresholdHR,
            "atria_workout_peak_hr": workout.peakHR,
            "atria_auto_gate_e_unchanged": true
        ]
        return HKWorkout(activityType: .traditionalStrengthTraining,
                         start: workout.start,
                         end: workout.end,
                         duration: workout.duration,
                         totalEnergyBurned: nil,
                         totalDistance: nil,
                         metadata: metadata)
    }

    private func confirmedSleepSample(for sleep: UserConfirmedSleep) -> HKCategorySample? {
        guard sleep.end > sleep.start else { return nil }
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: false,
            "atria_sleep_id": sleep.id,
            "atria_sleep_source": "user_confirmed",
            "atria_sleep_candidate_source": sleep.source,
            "atria_sleep_confidence": sleep.confidence,
            "atria_sleep_motion_source": sleep.motionSource,
            "atria_sleep_motion_validated": sleep.motionValidated,
            "atria_sleep_avg_hr": sleep.avgHR,
            "atria_sleep_peak_hr": sleep.peakHR,
            "atria_sleep_resting_hr": sleep.restingHR,
            "atria_sleep_sessions": sleep.sessions,
            "atria_sleep_samples": sleep.samples,
            "atria_auto_gate_e_unchanged": true,
            "atria_metric_promotions": 0
        ]
        return HKCategorySample(type: sleepType,
                                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                                start: sleep.start,
                                end: sleep.end,
                                metadata: metadata)
    }

    private func heartRateSamples(for session: SavedSession, snapshot: ExportSnapshot?) -> [HKSample] {
        guard session.end > session.start else { return [] }
        let metadata: [String: Any] = [
            HKMetadataKeyWasUserEntered: false,
            "atria_session_id": session.id.uuidString,
            "atria_label": session.label
        ]
        let exportedPointCount = min(snapshot?.hrPointCount ?? 0, session.points.count)
        return session.points.dropFirst(exportedPointCount).compactMap { point in
            guard point.bpm > 0 else { return nil }
            let start = session.start.addingTimeInterval(max(0, point.t))
            let end = start.addingTimeInterval(1)
            let sampleEnd = min(end, session.end)
            guard sampleEnd > start else { return nil }
            let quantity = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()),
                                      doubleValue: Double(point.bpm))
            return HKQuantitySample(type: heartRateType,
                                    quantity: quantity,
                                    start: start,
                                    end: sampleEnd,
                                    metadata: metadata)
        }
    }

    private static func hasHealthKitEntitlement() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else {
            return false
        }
        return text.contains("com.apple.developer.healthkit")
    }

    nonisolated private static func requestStatusLabel(_ status: HKAuthorizationRequestStatus) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .shouldRequest:
            return "should_request"
        case .unnecessary:
            return "unnecessary"
        @unknown default:
            return "unknown_future"
        }
    }
}
