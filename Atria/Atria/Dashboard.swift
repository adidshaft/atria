import SwiftUI

struct AtriaFrozenDailyStrainTarget: Codable, Equatable {
    /// W3-B (strain-targets fix 2): schema 2 adds `recoveryConfidence` — the
    /// Recovery tier that minted this target, stored as provenance. Decoding
    /// stays `decodeIfPresent`-defaulted (the established migration pattern
    /// below), so the on-device v1 blob — day/recovery/target only — still
    /// decodes.
    static let currentSchemaVersion = 2

    /// Tier provenance recorded for blobs written before schema 2 (and for
    /// canonical callers that predate the tier parameter). "legacy" is an
    /// unknown tier, not a claim — it is never treated as provisional.
    static let legacyRecoveryConfidence = "legacy"

    let schemaVersion: Int
    let day: Date
    let timeZoneIdentifier: String
    let recovery: Int
    let target: Double
    let loadAdjustment: Double
    let loadProvenance: String
    let recoveryConfidence: String
    let createdAt: Date

    /// True when this target was provisionally minted from a numeric
    /// AUTHORITATIVE `.unverified` recovery and no canonical settle has
    /// upgraded it yet. The value is real; surfaces label it "provisional".
    /// An upgraded blob stores e.g. "personal baseline_upgraded_from_unverified"
    /// (provenance relocates, never disappears) and is no longer provisional.
    var isProvisional: Bool {
        recoveryConfidence == Metrics.RecoveryEstimate.Confidence.unverified.rawValue
    }

    init(day: Date,
         timeZoneIdentifier: String,
         recovery: Int,
         target: Double,
         loadAdjustment: Double,
         loadProvenance: String,
         recoveryConfidence: String,
         createdAt: Date) {
        self.schemaVersion = Self.currentSchemaVersion
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recovery = recovery
        self.target = target
        self.loadAdjustment = loadAdjustment
        self.loadProvenance = loadProvenance
        self.recoveryConfidence = recoveryConfidence
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, day, timeZoneIdentifier, recovery, target
        case loadAdjustment, loadProvenance, recoveryConfidence, createdAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        day = try values.decode(Date.self, forKey: .day)
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? "legacy"
        recovery = try values.decode(Int.self, forKey: .recovery)
        target = try values.decode(Double.self, forKey: .target)
        loadAdjustment = try values.decodeIfPresent(Double.self, forKey: .loadAdjustment) ?? 0
        loadProvenance = try values.decodeIfPresent(String.self, forKey: .loadProvenance) ?? "legacy"
        recoveryConfidence = try values.decodeIfPresent(String.self, forKey: .recoveryConfidence)
            ?? Self.legacyRecoveryConfidence
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? day
    }
}

enum AtriaDailyStrainTargetStore {
    static let storageKey = "atria.coach.frozenDailyStrainTarget.v1"
    /// Audit slot for a relocated stale blob (see
    /// `liveSnapshotRelocatingStale`). Evidence of a mint outage lives here;
    /// it is never read back as a live coaching value.
    static let auditStorageKey = "atria.coach.frozenDailyStrainTarget.last"

    enum MutationAuthority: Equatable {
        /// Canonical Recovery may mint, replace, or explicitly invalidate.
        case canonical
        /// W3-B (strain-targets fix 2): a NUMERIC AUTHORITATIVE `.unverified`
        /// recovery may fill an EMPTY cycle slot so a stable daily target is
        /// reachable on limited-evidence days. It may never replace, upgrade,
        /// or delete existing durable state — weaker evidence cannot erase
        /// stronger — and the mint is labeled provisional through its stored
        /// tier provenance. The pending sleep-review presentation preview is
        /// also `.unverified` but is display evidence only; writers must
        /// strip it BEFORE deriving authority (Home's
        /// `recoveryAuthorizedForStrainTarget` gate; the scheduler only ever
        /// sees the authoritative projection).
        case provisionalMint
        /// Presentation-only/unknown Recovery may read a valid same-cycle
        /// target, but it may not write or delete durable coaching state.
        /// (One hygiene exception: a blob more than one full cycle stale is
        /// relocated to `auditStorageKey` on any resolve — no reader may
        /// return it, so relocation changes no coaching answer.)
        case preserveExisting
    }

    /// W1-C (strain-targets fix 1) + W3-B (fix 2): ONE honesty standard for
    /// the one durable strain-target write. Every writer — the Home hero
    /// snapshot and the notification scheduler — must derive its
    /// `MutationAuthority` from this gate. Canonical Recovery tiers may mint,
    /// replace, or explicitly invalidate the frozen daily target; a numeric
    /// authoritative `.unverified` tier may provisionally fill an empty cycle
    /// slot (never replace or delete); learning stays read-only. The
    /// pending-review presentation preview must never reach this gate with
    /// write intent (see `.provisionalMint`). Listing `.validated` mirrors
    /// the existing Home gate
    /// (`AtriaHomeModel.recoveryAuthorizedForStrainTarget`); it does not
    /// upgrade any tier — `.validated` remains reserved for the held-out
    /// outcome study.
    static func mintAuthority(
        recoveryConfidence: Metrics.RecoveryEstimate.Confidence?
    ) -> MutationAuthority {
        switch recoveryConfidence {
        case .personalBaseline, .validated:
            return .canonical
        case .unverified:
            return .provisionalMint
        case .learning, .none:
            return .preserveExisting
        }
    }

    static func resolve(recovery: Int?,
                        recoveryConfidence: Metrics.RecoveryEstimate.Confidence? = nil,
                        load: TrainingLoadSummary?,
                        recoveryIsAttributedToCurrentDay: Bool = true,
                        loadIsPrepared: Bool = true,
                        mutationAuthority: MutationAuthority = .canonical,
                        cycleStart: Date? = nil,
                        now: Date = Date(),
                        calendar: Calendar = .current,
                        defaults: UserDefaults = .standard) -> AtriaFrozenDailyStrainTarget? {
        let existing = liveSnapshotRelocatingStale(cycleStart: cycleStart,
                                                   now: now,
                                                   calendar: calendar,
                                                   defaults: defaults)
        let validSameCycleExisting: AtriaFrozenDailyStrainTarget? = {
            guard let existing,
                  existing.target.isFinite,
                  (0...21).contains(existing.target) else { return nil }
            let sameCycle = cycleStart.map {
                abs(existing.day.timeIntervalSince($0)) < 1
            } ?? calendar.isDate(existing.day, inSameDayAs: now)
            return sameCycle ? existing : nil
        }()
        switch mutationAuthority {
        case .preserveExisting:
            return validSameCycleExisting

        case .provisionalMint:
            // W3-B (strain-targets fix 2): a numeric authoritative
            // `.unverified` recovery may only FILL an empty cycle slot. An
            // existing same-cycle target — whatever tier minted it — always
            // stands, and nil attribution preserves, never deletes (the
            // repo's recovery-state defect class).
            if let validSameCycleExisting { return validSameCycleExisting }
            guard recoveryIsAttributedToCurrentDay,
                  loadIsPrepared,
                  let recovery else { return nil }
            return mint(recovery: recovery,
                        recoveryConfidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
                        load: load,
                        cycleStart: cycleStart,
                        now: now,
                        calendar: calendar,
                        defaults: defaults)

        case .canonical:
            guard recoveryIsAttributedToCurrentDay else {
                // A deleted/reclassified sleep must not leave a target that
                // implies recovery still belongs to the active physiological
                // cycle. Only a genuinely canonical caller may assert this.
                defaults.removeObject(forKey: storageKey)
                return nil
            }
            if let existingSnapshot = validSameCycleExisting {
                if recovery == nil || existingSnapshot.recovery == recovery {
                    if let upgraded = remintUpgradingRecoveryTier(existing: existingSnapshot,
                                                                 recoveryConfidence: recoveryConfidence,
                                                                 load: load,
                                                                 loadIsPrepared: loadIsPrepared,
                                                                 now: now,
                                                                 defaults: defaults) {
                        return upgraded
                    }
                    if let upgraded = remintUpgradingLearningLoad(existing: existingSnapshot,
                                                                 load: load,
                                                                 loadIsPrepared: loadIsPrepared,
                                                                 now: now,
                                                                 defaults: defaults) {
                        return upgraded
                    }
                    // Preserve through transient hydration, but never across a
                    // new wake boundary or a changed recovery for this sleep.
                    return existingSnapshot
                }
            }

            guard loadIsPrepared,
                  let recovery else {
                return nil
            }
            return mint(recovery: recovery,
                        recoveryConfidence: recoveryConfidence?.rawValue
                            ?? AtriaFrozenDailyStrainTarget.legacyRecoveryConfidence,
                        load: load,
                        cycleStart: cycleStart,
                        now: now,
                        calendar: calendar,
                        defaults: defaults)
        }
    }

    /// The one durable mint. `recoveryConfidence` is the tier provenance the
    /// blob records — callers pass their real tier; untyped legacy callers
    /// record "legacy", never a fabricated tier.
    private static func mint(recovery: Int,
                             recoveryConfidence: String,
                             load: TrainingLoadSummary?,
                             cycleStart: Date?,
                             now: Date,
                             calendar: Calendar,
                             defaults: UserDefaults) -> AtriaFrozenDailyStrainTarget {
        let base = Coach.baseStrainTarget(recovery: recovery)
        let adjustment: Double
        let provenance: String
        if let load, load.confidence != "learning", let ratio = load.ratio {
            (adjustment, provenance) = loadAdjustment(forRatio: ratio)
        } else {
            adjustment = 0
            provenance = "load_learning_at_mint"
        }
        let snapshot = AtriaFrozenDailyStrainTarget(
            day: cycleStart ?? calendar.startOfDay(for: now),
            timeZoneIdentifier: calendar.timeZone.identifier,
            recovery: recovery,
            target: min(max(base + adjustment, 4), 21),
            loadAdjustment: adjustment,
            loadProvenance: provenance,
            recoveryConfidence: recoveryConfidence,
            createdAt: now
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: storageKey)
        }
        return snapshot
    }

    static func loadSnapshot(defaults: UserDefaults = .standard) -> AtriaFrozenDailyStrainTarget? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self, from: data)
    }

    /// W3-B (strain-targets fix 5): the PRIOR cycle's frozen target, read for
    /// a DATED disclosure during the post-wake window where the cycle has
    /// flipped but recovery is not yet canonical (no target minted for the
    /// new cycle). Returns the live blob only when its day falls inside the
    /// immediately previous cycle window: a same-cycle blob is the live
    /// answer (`resolve` returns it as the target), and anything older is
    /// mint-outage evidence that hygiene relocates to the audit slot — never
    /// a coaching display. Read-only: never mutates storage, and callers must
    /// never present the result as the current cycle's target — only as the
    /// real prior target with its real date.
    static func priorCycleSnapshot(cycleStart: Date?,
                                   now: Date = Date(),
                                   calendar: Calendar = .current,
                                   defaults: UserDefaults = .standard) -> AtriaFrozenDailyStrainTarget? {
        guard let data = defaults.data(forKey: storageKey),
              let snapshot = try? JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                                       from: data),
              snapshot.target.isFinite,
              (0...21).contains(snapshot.target) else { return nil }
        let cycleAnchor = cycleStart ?? calendar.startOfDay(for: now)
        guard let previousCycleFloor = calendar.date(byAdding: .day,
                                                     value: -1,
                                                     to: cycleAnchor),
              snapshot.day >= previousCycleFloor,
              snapshot.day.timeIntervalSince(cycleAnchor) < -1 else {
            return nil
        }
        return snapshot
    }

    /// Shared acute:chronic thresholds for the frozen target's load leg — the
    /// mint path and the one-shot learning upgrade must never drift apart.
    static func loadAdjustment(forRatio ratio: Double) -> (adjustment: Double, provenance: String) {
        if ratio > 1.30 { return (-2, "load_high") }
        if ratio < 0.80 { return (1, "load_low") }
        return (0, "load_aligned")
    }

    /// W1-C (strain-targets fix 3): a target minted before training load was
    /// prepared carries `load_learning_at_mint`. When the SAME cycle later
    /// supplies a prepared, non-learning load, re-mint exactly once with the
    /// same recovery and the real adjustment. The old provenance stays legible
    /// inside the new string (e.g. `load_high_upgraded_from_learning`) —
    /// provenance relocates, never disappears — and because the upgraded
    /// provenance no longer equals `load_learning_at_mint`, a second upgrade
    /// can never fire: at most one per cycle. This is the one disclosed
    /// exception to the frozen-day rule ("a daily goal must not move
    /// backward"): the load leg may lower the target by 2 exactly once, and
    /// the provenance says so. Only reachable from a `.canonical` caller —
    /// `.preserveExisting` returns before the same-cycle branch.
    private static func remintUpgradingLearningLoad(
        existing: AtriaFrozenDailyStrainTarget,
        load: TrainingLoadSummary?,
        loadIsPrepared: Bool,
        now: Date,
        defaults: UserDefaults
    ) -> AtriaFrozenDailyStrainTarget? {
        guard existing.loadProvenance == "load_learning_at_mint",
              loadIsPrepared,
              let load,
              load.confidence != "learning",
              let ratio = load.ratio else { return nil }
        let (adjustment, provenance) = loadAdjustment(forRatio: ratio)
        let upgraded = AtriaFrozenDailyStrainTarget(
            day: existing.day,
            timeZoneIdentifier: existing.timeZoneIdentifier,
            recovery: existing.recovery,
            target: min(max(Coach.baseStrainTarget(recovery: existing.recovery) + adjustment, 4), 21),
            loadAdjustment: adjustment,
            loadProvenance: "\(provenance)_upgraded_from_learning",
            recoveryConfidence: existing.recoveryConfidence,
            createdAt: now
        )
        if let data = try? JSONEncoder().encode(upgraded) {
            defaults.set(data, forKey: storageKey)
        }
        return upgraded
    }

    /// W3-B (strain-targets fix 2): a target provisionally minted from a
    /// numeric authoritative `.unverified` recovery re-mints EXACTLY ONCE when
    /// the same cycle's recovery settles at a canonical tier with the same
    /// percent. The provisional tier stays legible inside the new provenance
    /// (e.g. "personal baseline_upgraded_from_unverified") — provenance
    /// relocates, never disappears — and because the stored tier is then no
    /// longer exactly "unverified", a second tier upgrade can never fire. The
    /// load leg is re-derived at upgrade time with the canonical caller's
    /// load, so the value may move exactly once, disclosed in provenance; if
    /// the provisional mint's load was still learning, that history is kept
    /// via the W1-C "_upgraded_from_learning" suffix (which also keeps the
    /// separate load upgrade from firing a second move). Tier downgrades
    /// never re-mint: canonical state stands. Only reachable from a
    /// `.canonical` caller.
    private static func remintUpgradingRecoveryTier(
        existing: AtriaFrozenDailyStrainTarget,
        recoveryConfidence: Metrics.RecoveryEstimate.Confidence?,
        load: TrainingLoadSummary?,
        loadIsPrepared: Bool,
        now: Date,
        defaults: UserDefaults
    ) -> AtriaFrozenDailyStrainTarget? {
        guard existing.isProvisional,
              let tier = recoveryConfidence,
              tier == .personalBaseline || tier == .validated else { return nil }
        let adjustment: Double
        let loadProvenance: String
        if loadIsPrepared, let load, load.confidence != "learning", let ratio = load.ratio {
            let (derivedAdjustment, derivedProvenance) = loadAdjustment(forRatio: ratio)
            adjustment = derivedAdjustment
            loadProvenance = existing.loadProvenance == "load_learning_at_mint"
                ? "\(derivedProvenance)_upgraded_from_learning"
                : derivedProvenance
        } else {
            // No prepared load at settle time: keep the existing load leg
            // byte-for-byte so the tier upgrade alone never moves the value.
            adjustment = existing.loadAdjustment
            loadProvenance = existing.loadProvenance
        }
        let upgraded = AtriaFrozenDailyStrainTarget(
            day: existing.day,
            timeZoneIdentifier: existing.timeZoneIdentifier,
            recovery: existing.recovery,
            target: min(max(Coach.baseStrainTarget(recovery: existing.recovery) + adjustment, 4), 21),
            loadAdjustment: adjustment,
            loadProvenance: loadProvenance,
            recoveryConfidence: "\(tier.rawValue)_upgraded_from_"
                + Metrics.RecoveryEstimate.Confidence.unverified.rawValue,
            createdAt: now
        )
        if let data = try? JSONEncoder().encode(upgraded) {
            defaults.set(data, forKey: storageKey)
        }
        return upgraded
    }

    /// W1-C (strain-targets fix 4): stale-blob hygiene. A stored target whose
    /// day predates the current cycle by more than one full cycle is evidence
    /// of a mint outage (the device's July-22 blob), not a live coaching
    /// value. Relocate the raw bytes to the audit slot: keeps the evidence,
    /// empties the live slot — never silently deleted, never returned. A blob
    /// from the immediately previous cycle is NOT relocated; the normal mint
    /// path replaces it without churn.
    private static func liveSnapshotRelocatingStale(
        cycleStart: Date?,
        now: Date,
        calendar: Calendar,
        defaults: UserDefaults
    ) -> AtriaFrozenDailyStrainTarget? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(AtriaFrozenDailyStrainTarget.self,
                                                       from: data) else {
            // Undecodable evidence stays where it is; hygiene never guesses.
            return nil
        }
        let cycleAnchor = cycleStart ?? calendar.startOfDay(for: now)
        guard let previousCycleFloor = calendar.date(byAdding: .day,
                                                     value: -1,
                                                     to: cycleAnchor),
              snapshot.day < previousCycleFloor else {
            return snapshot
        }
        defaults.set(data, forKey: auditStorageKey)
        defaults.removeObject(forKey: storageKey)
        return nil
    }
}

/// The core daily loop: recovery sets an "optimal strain" target for the day,
/// and we tell you whether to push, hold, or rest based on where today's strain
/// sits relative to that target.
enum Coach {

    /// Recovery → recommended strain target (0–21). Higher recovery earns a
    /// higher target; low recovery caps it low.
    static func optimalStrain(recovery: Int) -> Double {
        baseStrainTarget(recovery: recovery)
    }

    static func baseStrainTarget(recovery: Int) -> Double {
        let clamped = min(max(Double(recovery), 0), 100)
        if clamped <= 33 { return 9 }
        if clamped >= 67 { return 17 }
        return 9 + ((clamped - 33) / 34) * 8
    }

    static func liveStrainTarget(recovery: Int, accumulatedStrain strain: Double) -> Double {
        // A daily goal must not move backward as the user makes progress.
        // Recovery (and, in the overload below, training load) establishes the
        // target; accumulated strain only determines progress and guidance
        // state. Keep the argument for source compatibility with existing
        // callers while making the target stable for the civil day.
        _ = strain
        return baseStrainTarget(recovery: recovery)
    }

    struct Guidance: Equatable {
        let headline: String
        let detail: String
        let color: Color
        let target: Double?
        let state: String
        let reason: String

        static func == (lhs: Guidance, rhs: Guidance) -> Bool {
            lhs.headline == rhs.headline
                && lhs.detail == rhs.detail
                && lhs.target == rhs.target
                && lhs.state == rhs.state
                && lhs.reason == rhs.reason
        }
    }

    static func guide(recovery: Int?, strain: Double) -> Guidance {
        guard let r = recovery else {
            return Guidance(headline: "Building your baseline",
                            detail: "Recovery is learning; strain target stays off until enough local inputs are ready.",
                            color: .secondary, target: nil,
                            state: "learning",
                            reason: "recovery_unavailable")
        }
        let target = liveStrainTarget(recovery: r, accumulatedStrain: strain)
        if r < 34 {
            return Guidance(headline: "Prioritize recovery",
                            detail: "Recovery is low; keep strain light and let your body rebuild.",
                            color: .red, target: target,
                            state: "ready",
                            reason: "low_recovery")
        }
        if strain > target + 2 {
            return Guidance(headline: "Ease off",
                            detail: "You are past today's optimal strain; more risks overreaching.",
                            color: .orange, target: target,
                            state: "ready",
                            reason: "strain_above_target")
        }
        if strain < target - 2 {
            return Guidance(headline: "Room to push",
                            detail: "You can safely add strain to reach today's target.",
                            color: .green, target: target,
                            state: "ready",
                            reason: "strain_below_target")
        }
        return Guidance(headline: "On target",
                        detail: "Your strain matches what today's recovery supports.",
                        color: .blue, target: target,
                        state: "ready",
                        reason: "strain_on_target")
    }

    static func guide(recovery estimate: Metrics.RecoveryEstimate,
                      strain: Double,
                      load: TrainingLoadSummary? = nil,
                      frozenTarget: Double? = nil,
                      frozenRecovery: Int? = nil) -> Guidance {
        guard let percent = estimate.percent ?? frozenRecovery else {
            // estimate.detail is an internal "learning: <reason>" status string;
            // strip the redundant "learning:" prefix (the headline already says
            // "Guidance learning") so the sentence doesn't read the awkward
            // "…recovery data: learning: need resting HR."
            let rawDetail = estimate.detail.isEmpty ? "more data" : estimate.detail.replacingOccurrences(of: "_", with: " ")
            let detail = rawDetail.replacingOccurrences(of: "learning: ", with: "")
            return Guidance(headline: "Guidance learning",
                            detail: "Waiting for enough recovery data: \(detail).",
                            color: .secondary,
                            target: nil,
                            state: "learning",
                            reason: "recovery_\(estimate.confidence.rawValue)_not_ready")
        }
        if let frozenTarget {
            return guide(recovery: percent, strain: strain, frozenTarget: frozenTarget)
        }
        var guidance = guide(recovery: percent, strain: strain)
        guard let load, load.confidence != "learning", let ratio = load.ratio else {
            return guidance
        }

        let adjustedTarget: Double
        let loadClause: String
        let loadReason: String
        if ratio > 1.30 {
            adjustedTarget = max(4, (guidance.target ?? optimalStrain(recovery: percent)) - 2)
            loadClause = " Acute load is above your longer base, so today's target is softened."
            loadReason = "load_high"
        } else if ratio < 0.80 {
            adjustedTarget = min(21, (guidance.target ?? optimalStrain(recovery: percent)) + 1)
            loadClause = " Recent load is below your base, so there is room to rebuild gradually."
            loadReason = "load_low"
        } else {
            adjustedTarget = guidance.target ?? optimalStrain(recovery: percent)
            loadClause = " Load is aligned with your base."
            loadReason = "load_aligned"
        }

        if strain > adjustedTarget + 2 {
            guidance = Guidance(headline: "Ease off",
                                detail: "You are past today's adjusted strain target.\(loadClause)",
                                color: .orange,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        } else if strain < adjustedTarget - 2 {
            guidance = Guidance(headline: "Room to push",
                                detail: "You can add strain toward today's adjusted target.\(loadClause)",
                                color: .green,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        } else {
            guidance = Guidance(headline: "On target",
                                detail: "Your strain matches today's adjusted target.\(loadClause)",
                                color: .blue,
                                target: adjustedTarget,
                                state: guidance.state,
                                reason: "\(guidance.reason)_\(loadReason)")
        }
        return guidance
    }

    static func guide(recovery: Int, strain: Double, frozenTarget target: Double) -> Guidance {
        let safeTarget = min(max(target, 0), 21)
        if recovery < 34 {
            return Guidance(headline: "Prioritize recovery",
                            detail: "Recovery is low; keep strain light and let your body rebuild.",
                            color: .red, target: safeTarget,
                            state: "ready", reason: "low_recovery_frozen_daily_target")
        }
        if strain > safeTarget + 2 {
            return Guidance(headline: "Ease off",
                            detail: "You are past today's strain target.",
                            color: .orange, target: safeTarget,
                            state: "ready", reason: "strain_above_frozen_daily_target")
        }
        if strain < safeTarget - 2 {
            return Guidance(headline: "Room to push",
                            detail: "You can safely add strain toward today's target.",
                            color: .green, target: safeTarget,
                            state: "ready", reason: "strain_below_frozen_daily_target")
        }
        return Guidance(headline: "On target",
                        detail: "Your strain matches today's target.",
                        color: .blue, target: safeTarget,
                        state: "ready", reason: "strain_on_frozen_daily_target")
    }
}

/// Assessment §13.3 (2026-08-14): the daily coach SENTENCE now speaks the
/// whiteboard's language (personal HRV/RHR bands vs yesterday's measured
/// TRIMP). The recovery→9–17 kernel, the frozen daily target, and every
/// numeric target skin are unchanged; this rewrites only the words — and,
/// while the bands are still calibrating, hides the number (no target).
struct AtriaWhiteboardCoachSentence {
    struct DayContext: Equatable {
        let hrvMS: Int?
        let restingHR: Int?
        let baseline: AtriaBaselineTargetSnapshot
        let yesterdayTRIMP: Double?
        let yesterdayStrainDisplay: Double?
    }

    /// Guidance from a mature resting-HR band while the HRV band is still
    /// (or permanently) immature. Always names what it did NOT use.
    nonisolated static func restingOnlyGuidance(
        kernel: Coach.Guidance,
        context: DayContext,
        rhrZ: Double
    ) -> Coach.Guidance {
        let yesterdayTRIMP = context.yesterdayTRIMP
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let yesterdayStrain = context.yesterdayStrainDisplay
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let qualifier = " HRV is still calibrating, so this reads resting HR only."

        if rhrZ > 1 {
            let clause: String
            if let yesterdayTRIMP {
                clause = String(format: " — go easier than yesterday's %.0f TRIMP.", yesterdayTRIMP)
            } else if let yesterdayStrain {
                clause = String(format: " — go easier than yesterday's Strain %.1f.", yesterdayStrain)
            } else {
                clause = " — keep today easy."
            }
            return Coach.Guidance(
                headline: "Take today lighter than yesterday",
                detail: "Resting HR is above your typical band" + clause + qualifier,
                color: .orange,
                target: kernel.target,
                state: kernel.state,
                reason: "whiteboard_lighter_resting_only")
        }

        let headline: String
        let clause: String
        if let yesterdayTRIMP {
            headline = "Room to match yesterday"
            clause = String(format: " — room to repeat yesterday's %.0f TRIMP.", yesterdayTRIMP)
        } else if let yesterdayStrain {
            headline = "Room to match yesterday"
            clause = String(format: " — room to repeat yesterday's Strain %.1f.", yesterdayStrain)
        } else {
            headline = "Inside your resting-HR band"
            clause = " — no strain recorded yesterday, go by feel."
        }
        return Coach.Guidance(
            headline: headline,
            detail: "Resting HR is inside your typical band" + clause + qualifier,
            color: .green,
            target: kernel.target,
            state: kernel.state,
            reason: "whiteboard_match_resting_only")
    }

    static func rewrite(kernel: Coach.Guidance,
                        context: DayContext) -> Coach.Guidance {
        guard context.baseline.hrvTrusted, context.baseline.restingTrusted else {
            // Resting-only lane (field report 2026-08-19, item 13).
            //
            // This used to withhold ALL guidance until BOTH baselines matured.
            // On a strap that cannot deliver HRV that is not "calibrating", it is
            // permanent: the 2026-08-19 device had HRV on 1 of 43 days because RR
            // dropouts prevent a five-minute window from ever forming, so
            // `hrvTrusted` would never become true and the wearer would read
            // "Calibrating your baseline · 1 of 14 nights" forever.
            //
            // Resting HR does not share that limit — it learns from qualified
            // daytime low-HR windows (see the note at Insights.swift:298-300), and
            // it was trusted on this device. So when the resting band IS mature,
            // say what it measured and disclose what it did not, rather than
            // saying nothing. That is this file's neighbouring doctrine verbatim:
            // "Withholding is not more honest — it just leaves the wearer with
            // nothing while the app silently waits."
            //
            // Precedent for HRV-free guidance already exists in the recovery
            // model (`limitedEvidenceEstimateWithoutHRV`, HRV weighted exactly 0
            // at `.unverified` confidence), so this introduces no new claim class.
            if context.baseline.restingTrusted,
               let rhrZ = context.baseline.restingBandZ(restingHR: context.restingHR) {
                return restingOnlyGuidance(kernel: kernel, context: context, rhrZ: rhrZ)
            }
            return Coach.Guidance(
                headline: "Calibrating your baseline",
                detail: "\(min(context.baseline.hrvSampleCount, 14)) of 14 nights of HRV and resting heart rate build your personal bands.",
                color: .secondary,
                target: nil,
                state: kernel.state,
                reason: "whiteboard_calibrating")
        }
        guard let hrvZ = context.baseline.hrvBandZ(hrvMS: context.hrvMS),
              let rhrZ = context.baseline.restingBandZ(restingHR: context.restingHR) else {
            return Coach.Guidance(
                headline: "Waiting for this morning's numbers",
                detail: "Guidance starts after today's HRV and resting heart rate are measured.",
                color: .secondary,
                target: kernel.target,
                state: kernel.state,
                reason: "whiteboard_awaiting")
        }

        let yesterdayTRIMP = context.yesterdayTRIMP
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let yesterdayStrain = context.yesterdayStrainDisplay
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        let hrvLow = hrvZ < -1
        let rhrHigh = rhrZ > 1
        if hrvLow || rhrHigh {
            let cause: String
            if hrvLow, rhrHigh {
                cause = "HRV and resting HR are outside your typical bands"
            } else if hrvLow {
                cause = "HRV is below your typical band"
            } else {
                cause = "Resting HR is above your typical band"
            }
            let clause: String
            if let yesterdayTRIMP {
                clause = String(format: " — go easier than yesterday's %.0f TRIMP.", yesterdayTRIMP)
            } else if let yesterdayStrain {
                clause = String(format: " — go easier than yesterday's Strain %.1f.", yesterdayStrain)
            } else {
                clause = " — keep today easy."
            }
            return Coach.Guidance(
                headline: "Take today lighter than yesterday",
                detail: cause + clause,
                color: .orange,
                target: kernel.target,
                state: kernel.state,
                reason: "whiteboard_lighter")
        }

        let clause: String
        let headline: String
        if let yesterdayTRIMP {
            headline = "Room to match yesterday"
            clause = String(format: " — room to repeat yesterday's %.0f TRIMP.", yesterdayTRIMP)
        } else if let yesterdayStrain {
            headline = "Room to match yesterday"
            clause = String(format: " — room to repeat yesterday's Strain %.1f.", yesterdayStrain)
        } else {
            headline = "Inside your typical bands"
            clause = " — no strain recorded yesterday, go by feel."
        }
        return Coach.Guidance(
            headline: headline,
            detail: "HRV and resting HR are inside your typical bands" + clause,
            color: .green,
            target: kernel.target,
            state: kernel.state,
            reason: "whiteboard_match")
    }
}

