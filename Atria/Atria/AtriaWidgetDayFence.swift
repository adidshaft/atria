import Foundation

// 2026-08-20 (widget-sync RC1/RC2): the widget extension's civil-day identity
// fence blanked EVERY family at local midnight, including the wake-to-wake
// steps/strain values whose own publisher-persisted cycle fences legitimately
// extend past midnight for a shifted sleeper (a 13:15–19:15 cycle expires
// mid-afternoon the NEXT civil day). The fence decision is extracted here as a
// pure function compiled into the app target so it gets direct unit coverage —
// the same coverage AtriaIntentSnapshotStore.snapshotAnswersForCurrentDay
// already has. The widget target compiles a byte-identical copy in
// AtriaWidget/AtriaWidget.swift (the two targets share no source file);
// AtriaWidgetDayFenceTests pins the two mirror blocks byte-identical.
// ATRIA-DAY-FENCE-MIRROR-BEGIN
/// Decision for one decoded widget payload at render time.
/// `belongsToCurrentDay` is the H10 civil-day identity; `keepsSteps` /
/// `keepsStrain` say whether those families survive a day-key mismatch
/// because their own physiological cycle fences are still in the future.
/// Recovery, sleep, biomarkers, and the whiteboard never survive civil
/// midnight.
struct AtriaWidgetDayFenceDecision: Equatable {
    let belongsToCurrentDay: Bool
    let keepsSteps: Bool
    let keepsStrain: Bool
}

enum AtriaWidgetDayFence {
    /// Pure day-fence resolution. New payloads compare the explicit publisher
    /// day key plus its timezone identity; legacy payloads only survive while
    /// `createdAt` is on the reader's current local day. Steps and strain are
    /// wake-to-wake physiological values: while their publisher-persisted
    /// cycle expiry is still in the future they remain the CURRENT cycle's
    /// values and survive the civil-day blanking with their partial/frontier
    /// disclosures intact. Absent fences (legacy payloads) keep failing
    /// closed exactly as before. This split must hold even when no rollover
    /// republish ever fires — the fence is never clearable only by the
    /// success it blocks.
    static func resolve(
        displayCivilDayKeyMatchesCurrentDay: Bool?,
        displayTimeZoneMatchesCurrentCalendar: Bool,
        createdAtIsOnCurrentDay: Bool,
        stepsCycleExpiresAt: Date?,
        strainCycleExpiresAt: Date?,
        now: Date
    ) -> AtriaWidgetDayFenceDecision {
        let belongsToCurrentDay: Bool
        if let displayCivilDayKeyMatchesCurrentDay {
            belongsToCurrentDay = displayCivilDayKeyMatchesCurrentDay
                && displayTimeZoneMatchesCurrentCalendar
        } else {
            belongsToCurrentDay = createdAtIsOnCurrentDay
        }
        return AtriaWidgetDayFenceDecision(
            belongsToCurrentDay: belongsToCurrentDay,
            keepsSteps: stepsCycleExpiresAt.map { now < $0 } == true,
            keepsStrain: strainCycleExpiresAt.map { now < $0 } == true
        )
    }
}
// ATRIA-DAY-FENCE-MIRROR-END
