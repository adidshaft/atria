# Atria field-report — verified root causes (workflow wf_d58bdc20-521, 30 agents)

Each finding was independently re-derived AND adversarially refuted by two separate agents.
`refuted N/2` = how many of the two challengers rejected it.


## SURVIVED

### Item 4 — real-defect (refuted 0/2, confidence high)

**Root cause**

`AtriaCurrentDayPresentation.resolve` gates the Today rings on CIVIL-day equality, not on the physiological cycle it was handed. At `Atria/Atria/AtriaCurrentDayPresentation.swift:75-78` it computes `displayCivilDay = calendar.startOfDay(for: now)` and `sourceIsToday = calendar.isDate(cycleValueSourceDay, inSameDayAs: displayCivilDay)`. `cycleValueSourceDay` is the anchoring wake's civil day (AtriaHomeView.swift:12137-12140). At 00:00:00 the displayed civil day advances while the wake does not, `sourceIsToday` flips false, and the fall-through Resolution at AtriaCurrentDayPresentation.swift:102-123 returns the terminal awaiting state: `recoveryOverride` = a RecoveryEstimate with `percent: nil` and detail "Awaiting current sleep" (:113-119), `strainOverride: currentDayPartialStrain ?? 0` (:120 — nil at 00:00 because no rollup row exists yet for the new civil day, per the `todayRollup` lookup at AtriaHomeView.swift:12141-12143), and `sleepIsAwaitingCurrentSleep: true` (:121). Those three land on the rings at AtriaHomeView.swift:12174 (`presentedRecovery`), :12269 (`presentedStrain`), and :12320-12322 (dayTRIMP/muscularTRIMP forced to 0); the Today sleep ring separately blanks via `sleepIsCurrentDayPrimary` (AtriaCurrentDayPresentation.swift:129-136, "wake must fall on today's civil day") consumed at AtriaTodayScreen.swift:1706-1712, which nils `currentDaySleep` so value becomes `--` (:1713-1717) and `fillFraction` becomes nil (:1739-1742).

The decisive proof this is an over-broad gate and not a data problem: `resolve` is HANDED the real physiological rollover — `cycleEnd:` is `AtriaPhysiologicalCycle.nextNoSleepRollover(...)` (AtriaHomeView.swift:12151-12155), i.e. wake + 1 civil day + 30 min grace (Sessions.swift:168-190, 226-250) — and never consults it in any branch. Inside `resolve` `cycleEnd` appears only in the two identity constructors (:85, :107). The math authority `AtriaPhysiologicalCycle.current` (Sessions.swift:130-165) keeps the cycle anchored at the last main-sleep wake and rolls over ONLY at that fallback, never at midnight, and the underlying values remain real: `recoveryProjectionForPresentation` is purely cycle-based (Sessions.swift:23883-23901) and `strain` comes from `savedAggregate` windowed at `physiologicalCycle.start` (AtriaHomeView.swift:12187-12192). So at 00:01 the app still HAS correct values and deliberately discards them.

Two more sites key on the same civil boundary: the widget publisher sets `recoveryExpiresAt`/`sleepExpiresAt` to `displayDayEnd` = start of next civil day (WidgetSnapshot.swift:1637, 1743-1744), and the widget extension's decode sanitizer `atriaEnforceCurrentDayIdentity` wipes recovery, sleep, strain AND steps on a civil-day-key mismatch (AtriaWidget/AtriaWidget.swift:246-282).

The design intent was "not blank — a dated disclosure" (AtriaCurrentDayPresentation.swift:6-8, 32-40). That half was never wired: `AtriaPriorCycleDisclosure` is built at AtriaHomeView.swift:12166-12172 and carried on HeroSnapshot at :12282, but no view in Atria/Atria or Atria/AtriaWidget ever reads it; the widget passes `priorCycle: nil` outright (WidgetSnapshot.swift:1630); and `AtriaMetricPresentationValueState.priorCycleDisclosure` (:15) is never produced by `resolve`. The user therefore gets a blank ring with no date, which is precisely what item 4 describes.

**Evidence**

- Atria/Atria/AtriaCurrentDayPresentation.swift:75-78 — displayCivilDay = calendar.startOfDay(for: now); sourceIsToday = calendar.isDate($0, inSameDayAs: displayCivilDay) — the civil-midnight gate
- Atria/Atria/AtriaCurrentDayPresentation.swift:102-123 — fall-through Resolution: recovery percent nil + awaitingCurrentSleepDetail, strainOverride: currentDayPartialStrain ?? 0, sleepIsAwaitingCurrentSleep: true
- Atria/Atria/AtriaCurrentDayPresentation.swift:85,107 — cycleEnd is stored on the identity and used in NO condition anywhere in resolve
- Atria/Atria/AtriaCurrentDayPresentation.swift:129-136 — sleepIsCurrentDayPrimary returns calendar.isDate(sleepEnd, inSameDayAs: startOfDay(now))
- Atria/Atria/AtriaHomeView.swift:12137-12140 — cycleValueSourceDay = latestSleep.map { $0.end ?? $0.day } for the .mainSleep boundary
- Atria/Atria/AtriaHomeView.swift:12148-12172 — resolve() call site; cycleEnd: AtriaPhysiologicalCycle.nextNoSleepRollover(...) at :12151; priorCycle built at :12166
- Atria/Atria/AtriaHomeView.swift:12174, 12269, 12320-12322 — presentedRecovery / presentedStrain / dayTRIMP+muscularTRIMP zeroed by the overrides
- Atria/Atria/AtriaTodayScreen.swift:1706-1717,1739-1742 — displaySleepIsCurrentDay nils currentDaySleep -> value AtriaCompactMetricPresentation.noValue and fillFraction nil
- Atria/Atria/AtriaTodayScreen.swift:1791-1805 — displayRecovery renders "--" the moment estimate.percent is nil
- Atria/Atria/Sessions.swift:130-165 — AtriaPhysiologicalCycle.current anchors on latest.end; no civil-midnight rollover
- Atria/Atria/Sessions.swift:168-190 — firstNoSleepFallback = wake + 1 civil day + noSleepSettlementGrace (30 min): the real rollover
- Atria/Atria/Sessions.swift:23883-23901 — recoveryProjectionForPresentation is cycle-based, so a real value still exists past midnight
- Atria/Atria/AtriaHomeView.swift:12187-12192 — strain derives from savedAggregate windowed at physiologicalCycle.start, so real strain still exists past midnight
- Atria/Atria/AtriaOverviewSections.swift:1832-1845 — AtriaOverviewCurrentSleep.resolve already uses the CORRECT gate: firstNoSleepFallback(after: wake) > now
- Atria/Atria/WidgetSnapshot.swift:2185-2205 — cumulativeStrainCycleExpiration is cycle-based (cycle.start + 1 civil day): the existing correct precedent
- Atria/Atria/WidgetSnapshot.swift:1637,1743-1744 — displayDayEnd = startOfDay+1day assigned to recoveryExpiresAt and sleepExpiresAt (the inconsistent civil lane)
- Atria/Atria/WidgetSnapshot.swift:1630 — widget resolve passes priorCycle: nil, so widgets have no disclosure at all
- Atria/AtriaWidget/AtriaWidget.swift:246-282 — atriaEnforceCurrentDayIdentity nils recoveryPercent/sleepHours/strain/steps on civil-day-key mismatch
- Atria/Atria/AtriaHomeView.swift:9409-9413, 9583, 12282 + grep across Atria/Atria and Atria/AtriaWidget — priorCycleDisclosure has construction and Equatable sites only; no view reads it
- Atria/AtriaTests/AtriaCurrentDayPresentationTests.swift:18,50-83 — the incident fixture (wake Aug-12 15:27, now Aug-13 14:43) that motivated the blanking, and testNoCurrentDayRowYieldsTerminalAwaitingStates asserting strainOverride == 0
- Atria/Atria/AtriaHomeView.swift:11006-11013 — the stress lane already expires on nextNoSleepRollover, a second in-repo precedent for the cycle boundary
- live device defaults: notification.sleepEvent.lastDay='2026-08-18' lastKind='morning_summary' lastDurationMinutes=303 — an Aug-18-anchored cycle was live at the 01:57 Aug-19 pull, so the rings were in the awaiting state

**Proposed fix**

Move the Today identity off civil midnight and onto the physiological rollover the function is already given, and pay the label debt that justified the blanking. Four parts; part 3 is a hard precondition, not optional polish.

1. Atria/Atria/AtriaCurrentDayPresentation.swift:9-19 — add a fourth state:
   `case currentCycleAcrossMidnight  // the live cycle's own values, shown under the CYCLE's date`

2. Atria/Atria/AtriaCurrentDayPresentation.swift — insert one branch after the `sourceIsToday` block (after :96, before the awaiting fall-through at :98):
```swift
// The civil date moved but the physiological day did not. The cycle that
// produced these values is still the one the user is living in, so the
// values stay primary — under the CYCLE's date, never today's label.
let cycleIsLive = cycleEnd.map { now < $0 } ?? false
if cycleIsLive, anchorSleepID != nil {
    return Resolution(
        identity: .init(displayCivilDay: displayCivilDay,
                        cycleStart: cycleStart,
                        cycleEnd: cycleEnd,
                        sourceSleepID: anchorSleepID,
                        sourceCivilDay: cycleValueSourceDay,
                        valueState: .currentCycleAcrossMidnight,
                        calculatedAt: now),
        recoveryOverride: nil,          // cycle projection stays primary
        strainOverride: nil,            // real accumulating strain stays
        sleepIsAwaitingCurrentSleep: false,
        priorCycle: nil)                // not prior — the open cycle
}
```
`cycleEnd` is already `nextNoSleepRollover` (wake + 1 civil day + 30 min). Once it passes, the existing :102-123 awaiting branch runs unchanged, so a multi-day all-nighter still fails closed. This is the same boundary `AtriaOverviewCurrentSleep.resolve` (AtriaOverviewSections.swift:1838-1844) and the stress lane (AtriaHomeView.swift:11006-11013) already use.

3. MANDATORY label change — otherwise this reintroduces the Aug-12/13 lie verbatim. When `valueState == .currentCycleAcrossMidnight`, the word "Today" must be replaced by the cycle's date at every Today-labelled surface: AtriaHomeView.swift:807 (`case .overview: return "Today"`), AtriaHomeView.swift:1377 (`tabNavigation(title: "Today", ...)`), and AtriaTodayScreen.swift:3044 (the ring-browser "TODAY" chip). Render the cycle date, e.g. "AUG 18 DAY · STILL OPEN". Also finally render the disclosure line the design promised: wire `HeroSnapshot.priorCycleDisclosure` (AtriaHomeView.swift:9413, currently read by nobody) into a caption under the rings — "Your Aug 18 day — open until tonight's sleep". Ship the relabel in the SAME commit as part 2.

4. Atria/Atria/AtriaCurrentDayPresentation.swift:129-136 — change `sleepIsCurrentDayPrimary` from a civil-day test to a cycle-anchor test:
```swift
static func sleepAnchorsCurrentCycle(sleepEnd: Date?, cycleStart: Date) -> Bool {
    guard let sleepEnd else { return false }
    return sleepEnd >= cycleStart
}
```
Update AtriaTodayScreen.swift:1706-1710 and WidgetSnapshot.swift:1635-1636 to pass `physiologicalCycle.start`. This restores the sleep ring's hours and fill past midnight and clears them the instant a new main sleep anchors a new cycle — exactly the user's "unless the night's sleep is completed".

5. Widget parity: WidgetSnapshot.swift:1743-1744 — set `recoveryExpiresAt`/`sleepExpiresAt` to `cumulativeStrainCycleExpiration(cycle:confirmedSleeps:calendar:)` (WidgetSnapshot.swift:2185-2205) instead of `displayDayEnd` (:1637); and at :1740 publish the CYCLE's civil day key rather than `now`'s when the resolution is `.currentCycleAcrossMidnight`, so `atriaEnforceCurrentDayIdentity` (AtriaWidget/AtriaWidget.swift:246-282) stops wiping the whole payload — including cycle-keyed steps and strain — at midnight.

Explicitly NOT changed: `AtriaPhysiologicalCycle`, the recovery projection, the strain window, `dayPrimaryChoice`, and the frozen strain target. This is a presentation-identity change only.

**Test plan**

Add to Atria/AtriaTests/AtriaCurrentDayPresentationTests.swift (scheme AtriaTests), reusing its existing `day(_:)`/`wake`/`resolve(...)` helpers with a fixed `Calendar.current`:

1. `testLiveCycleSurvivesCivilMidnight` — wake = day(0) + 7h, now = day(1) + 0h30m, cycleEnd = wake + 24h30m. Assert `identity.valueState == .currentCycleAcrossMidnight`, `recoveryOverride == nil`, `strainOverride == nil`, `sleepIsAwaitingCurrentSleep == false`, `identity.sourceCivilDay == day(0)`, `identity.displayCivilDay == day(1)` (the label layer must be able to see the two differ), `identity.sourceSleepID == "sleep-aug12"`.
2. `testCycleRolloverStillFailsClosed` — same wake, now = day(1) + 7h31m (past wake+24h30m) with `cycleEnd` in the past. Assert `.awaitingCurrentSleep`, `recoveryOverride?.percent == nil`, `strainOverride == 0`, `sleepIsAwaitingCurrentSleep == true`. This is the guard that keeps a multi-day all-nighter honest.
3. `testSleepPrimaryFollowsTheAnchoringWakeNotTheCivilDay` — `sleepAnchorsCurrentCycle(sleepEnd: wake, cycleStart: wake)` true when `now` is day(1) 02:00; false when `cycleStart` is a NEWER wake (a new night landed), proving the ring hands off rather than sticking.
4. Rewrite the existing `testTodayNeverWearsThePriorCycleAsPrimary` (:50-83) so it pins the invariant that actually protects the user: whenever `identity.valueState != .current`, `identity.displayCivilDay != identity.sourceCivilDay`, i.e. no surface may print the bare word "Today" over a foreign-dated value. Its old assertion (value must be blanked) is the behaviour item 4 reports and must be replaced deliberately, not silently.
5. Label pin, in the source-scan idiom this repo already uses (AtriaSleepStageIntegrityTests.swift:149, AtriaWidgetBatteryInvalidationTests.swift:2428): assert AtriaHomeView.swift:807/1377 and AtriaTodayScreen.swift:3044 consult `valueState` rather than emitting a literal "Today" unconditionally, so part 3 cannot regress out.
6. Widget: extend AtriaWidgetBatteryInvalidationTests with a midnight-crossing snapshot — publish at day(0) 23:50 with cycleEnd day(1) 07:30, run `atriaEnforceCurrentDayIdentity(now: day(1) + 0h10m)`, assert `recoveryPercent`, `sleepHours`, `strain` and `steps` all survive; then at `now = cycleEnd + 1s` assert they clear.

Run the focused suite only (`AtriaCurrentDayPresentationTests`, `AtriaSleepActivityConsistencyTests`, `AtriaWidgetBatteryInvalidationTests`) — these suites share process/defaults, so avoid a whole-target run in the same pass.

**Noticed nearby**

1. The "dated disclosure" that justified blanking the rings was never built. `AtriaPriorCycleDisclosure` is constructed at AtriaHomeView.swift:12166-12172 and stored on HeroSnapshot at :12282, but a grep across Atria/Atria and Atria/AtriaWidget finds only construction and the Equatable comparison at :9583 — no view ever reads it. `AtriaMetricPresentationValueState.priorCycleDisclosure` (AtriaCurrentDayPresentation.swift:15) is likewise never produced by `resolve`. The Today-screen sleep ring is the ONLY surface with any dated fallback text ("Last cycle · Aug 18 · 7h", AtriaTodayScreen.swift:1725), and even there the value is `--` and the fill is nil. Recovery and strain go blank with no date whatsoever. So the shipped behaviour is strictly worse than the documented design.

2. The widget publisher is internally inconsistent on the same screen: steps and strain expire on the PHYSIOLOGICAL cycle (`strainCycleExpiresAt` / `stepsCycleExpiresAt` from `cumulativeStrainCycleExpiration`, WidgetSnapshot.swift:1584-1588, 2185-2205), while recovery and sleep expire at CIVIL midnight (`displayDayEnd`, :1637, 1743-1744). Then `atriaEnforceCurrentDayIdentity` (AtriaWidget/AtriaWidget.swift:257-282) nils the cycle-keyed steps and strain too on a civil-day-key mismatch — so the civil gate overrides the cycle gate that the same file went to the trouble of computing.

3. This is NOT starved by the 4 h stall. The blanking is pure date arithmetic in the presentation layer with no dependency on live HR, sync state, or the drain backlog; it fires at 00:00:00 with a perfectly synced strap. The 4 h dead window is orthogonal to item 4.

4. Adjacent to items 5/6 (not investigated here, flagging only): `AtriaOverviewCurrentSleep.resolveDisplayEvidence` pins an unresolved sleep candidate for 48 h across the midnight rollover (AtriaOverviewSections.swift:1854-1861, 1888-1899). That deliberate 48 h sticky pin is a plausible mechanism for item 5's "another sleep recommendation keeps going after it was stopped" and deserves its own look.

**Challenger 1 — refuted=False**

MECHANISM CONFIRMED — I read every cited site and the control flow reaches the described state. Line numbers are accurate.

1) The gate. /Users/amanpandey/projects/atria/Atria/Atria/AtriaCurrentDayPresentation.swift:75-78 is verbatim as claimed (`displayCivilDay = calendar.startOfDay(for: now)`; `sourceIsToday = calendar.isDate($0, inSameDayAs: displayCivilDay) ?? false`). The file's own header at :58-63 states the intent explicitly: "regardless of whether the wake-to-wake rollover has fired yet" — so the civil gate is deliberate, not accidental, which is exactly the over-broad-gate claim.

2) `cycleEnd` is inert. I read the whole 159-line file: `cycleEnd` appears only at :85 and :107 (identity constructors). No branch consults it. Confirmed.

3) Producer. AtriaHomeView.swift:12137-12139 is `physiologicalCycle.boundaryKind == .mainSleep ? latestSleep.map { $0.end ?? $0.day } : physiologicalCycle.start`; `latestSleep` = `store.currentPhysiologicalMainSleep` (Sessions.swift:23683-23693), which returns the ANCHOR night while `boundaryKind == .mainSleep` irrespective of civil day. So past midnight `cycleValueSourceDay` is yesterday → `sourceIsToday` false → the :102-123 fall-through. (Even if it were nil, `?? false` lands in the same branch — the conclusion is robust to that edge.)

4) The values really do still exist. `homeSavedAggregate` windows at `cycle.start` — Sessions.swift:24576-24578 (`let cycle = AtriaPhysiologicalCycle.current(...); let day = cycle.start`) and :24677 (`let day = cycleStart ?? calendar.startOfDay(for: now)`), and the view-level `SavedAggregate.cycleStart` (AtriaHomeView.swift:9846-9847, built at :11227) is the physiological cycle start. So at 00:01 `savedTodayTRIMP` still covers the whole cycle and `recoveryProjectionForPresentation` (Sessions.swift:23877-23910) is cycle-based. The app has real values and discards them. The "decisive proof" holds.

5) Blast radius verified: AtriaHomeView.swift:12174 (`presentedRecovery`), :12269 (`presentedStrain`), :12320-12322 (dayTRIMP/muscularTRIMP forced to 0), :12282 (disclosure carried). Chain to screen confirmed: makeHeroSnapshot (:12078) → heroStore.state (:11521) → AtriaTodayScreen `displayHero` (:1385, returns `hero`) → `displayRecovery` (:1791-1805) → `recoveryMetric` (:1952-1964, `fill: display.percent.map{...}` → nil). Sleep: AtriaTodayScreen.swift:1706-1717, 1739-1742 exactly as described.

6) Widget lanes verified exactly: WidgetSnapshot.swift:1630 (`priorCycle: nil`), :1637 (`display

_Corrections:_ EVIDENCE CORRECTIONS (do not change the verdict, but the report should be accurate):

C1. The recovery ring does NOT read "Awaiting current sleep". `displayRecovery` (AtriaTodayScreen.swift:1801-1805) passes the estimate detail through `AtriaRecoveryAvailabilityPresentation.detail` (/Users/amanpandey/projects/atria/Atria/Atria/AtriaTriRing.swift:132-156), which matches none of "need saved sleep"/"need a steady hrv"/"need resting hr"/"rhr baseline"/"hrv baseline" and therefore returns **"Recovery evidence incomplete"** (or "Needs sleep, HRV & RHR" with empty baselines). That is worse than claimed: the ring asserts the evidence is incomplete while a full validated cycle recovery exists.

C2. "Blank ring with no date" is overstated for sleep. AtriaTodayScreen.swift:1724-1725 renders a dated fallback: `"Last cycle · <Aug 18> · <7h 32m>"` from `latestDisplaySleep`. A dated disclosure DOES exist on the sleep ring — just not via `AtriaPriorCycleDisclosure`. The "never wired" charge is correct only for the disclosure STRUCT and for the recovery/strain rings.

C3. Only two of the three overrides land. `Resolution.sleepIsAwaitingCurrentSleep` is dead: grep across Atria/ shows it declared (:54) and set (:93, :121) and read nowhere in product code. The sleep blanking is entirely `sleepIsCurrentDayPrimary` in-app and `widgetSleepIsCurrentDay` in the widget (WidgetSnapshot.swift:1635-1636 → :1667-1674).

C4. Not proven, and not needed: I did not confirm that no rollup row exists for the fresh civil day at 00:01. Either way the outcome is the same class of defect (an existing row's `strain` is civil-day-windowed, ≈0 just after midnight). Also note there is no midnight-scheduled republish — `savedAggregateCycleRolloverTask` (AtriaHomeView.swift:11277-11291) schedules only on `nextNoSleepRollover` — so the flip lands on the next natural refresh, not at 00:00:00 exactly.

FIX CORRECTIONS:

F1 (load-bearing, the fix is wrong as written). `let cycleIsLive = cycleEnd.map { now < $0 } ??

**Challenger 2 — refuted=False**

I re-derived this from the code without leaning on their answer and arrived at the same mechanism, with every load-bearing citation verified.

CONFIRMED CHAIN
1. `AtriaCurrentDayPresentation.resolve` (Atria/Atria/AtriaCurrentDayPresentation.swift:75-78) makes exactly one decision, and it is civil: `displayCivilDay = calendar.startOfDay(for: now)`, `sourceIsToday = calendar.isDate(cycleValueSourceDay, inSameDayAs: displayCivilDay)`. Everything downstream hangs off that single boolean.
2. `cycleValueSourceDay` is the anchoring wake's civil day (AtriaHomeView.swift:12137-12139). At 00:00:00 `displayCivilDay` advances, the wake does not, `sourceIsToday` flips false, and the fall-through Resolution (AtriaCurrentDayPresentation.swift:102-123) returns `recoveryOverride` with `percent: nil` + detail "Awaiting current sleep" (:113-119), `strainOverride: currentDayPartialStrain ?? 0` (:120), `sleepIsAwaitingCurrentSleep: true` (:121).
3. Those land on the rings: `presentedRecovery` (AtriaHomeView.swift:12174) → `displayRecovery` returns `("--", …, nil)` (AtriaTodayScreen.swift:1791-1804) → `recoveryMetric.fill = display.percent.map{…}` = nil (AtriaTodayScreen.swift:1952-1966), empty arc. `presentedStrain` (AtriaHomeView.swift:12269) → `strainMetric` fill from `displayHero.strain` (AtriaTodayScreen.swift:1969-1985). `dayTRIMP`/`muscularTRIMP` forced to 0 (AtriaHomeView.swift:12320-12322). Sleep ring blanks through the separate gate `sleepIsCurrentDayPrimary` (AtriaCurrentDayPresentation.swift:129-136) consumed at AtriaTodayScreen.swift:1706-1711 → value `--` (:1713-1718), `fillFraction` nil (:1737-1742).
4. The gate is over-broad, not a data problem. `resolve` is handed `cycleEnd = AtriaPhysiologicalCycle.nextNoSleepRollover(...)` (AtriaHomeView.swift:12151-12155) and never reads it in any branch — grep of the whole 159-line file shows `cycleEnd` only at :85 and :107, both inside identity constructors. The math authority is untouched by midnight: `AtriaPhysiologicalCycle.current` (Sessions.swift:130-165) stays anchored at the last wake and rolls over only at `firstNoSleepFallback` = wake + 1 civil day + 30 min grace (Sessions.swift:172-190; `nextNoSleepRollover` :196-226); `savedAggregate` windows on `physiologicalCycle.start` (AtriaHomeView.swift:11227-11249, 12200) and `recoveryProjectionForPresentation` is cycle-based (Sessions.swift:23876-23901). The values still exist at 00:01 and are deliberately discarded.
5. Widget parity sites confirmed: publisher sets `reco

_Corrections:_ Their mechanism stands. Four refinements, one of which materially changes the fix:

1. "strainOverride ... nil at 00:00 because no rollup row exists yet" is an assumption, not a guarantee, and the other branch is worse. `currentDayPartialStrain` is `todayRollup?.strain` (AtriaHomeView.swift:12165) keyed on the NEW civil day, and rollup rows are civil-day-bucketed from `SavedDailyMetric` and persisted asynchronously (Sessions.swift:12127-12168). If a row for the new civil day already exists — likely when the user is awake and wearing the strap through midnight, which is exactly this report — the strain ring shows a freshly-restarted near-zero number ("≥ 0.4") instead of the real ~12 accumulated cycle strain, because `presentedStrainConfidence` is recomputed with `additionalIncompleteEvidence: true` (AtriaHomeView.swift:12270-12277). A plausible-looking wrong number is a worse honesty failure than "--". Both branches are the same defect; the writeup should not pin it to nil.

2. Add AtriaHomeView.swift:12179, `let recoveryIsFromPreviousSleep = false`, hard-coded by the same commit. The old carry marker that at least said "yesterday" was deleted at the same time the replacement disclosure went unrendered — that is why the user sees a bare blank with no date anywhere.

3. THE FIX CANNOT BE A LOOSENED GATE ALONE, or it is a straight regression of 1721d606. Under `now < cycleEnd` the Aug-12/13 incident fixture (wake 15:27 Aug 12, now 14:43 Aug 13, cycleEnd 15:57 Aug 13) is *inside* the open cycle, so any predicate of the form "keep the values while the cycle is open" restores exactly the 92 / 9h12 / 3.3 that commit was written to kill. The lie in that incident was the LABEL, not the values. So the change is two-part and both parts must land together:
   (a) in `resolve`, before the civil comparison, branch on the cycle it is already handed — if `cycleEnd != nil && now < cycleEnd && anchorSleepID != nil`, return the cycle values as primary (`recoveryOverride: nil`, `strain


---

### Item 5 — real-defect (refuted 0/2, confidence high)

**Root cause**

Settlement of a sleep review is recorded against ONE time window, but the review is re-minted by three independent producers that describe the same night with materially different windows and a fresh id every time. Two key mismatches, one per half of the user's sentence.

(A) "even if you save it" — the escape hatch after Confirm. `confirmSleepHistoryNight` persists the record with the DETECTOR's own source string: `reviewedSleepSource` (Sessions.swift:35127-35134) returns `night.source` verbatim when it is in `explicitSleepSources` (Sessions.swift:54057-54069 — "sleep_candidate", "sleep_window", "validated_sleep_window"), else "sleep_window". None of those carry the `manual_` / `user_adjusted_` prefixes that `isUserAuthoredSleepSource` (Sessions.swift:38793) tests, so `isExtendableAutoNight` (Sessions.swift:38819-38822) still classifies an EXPLICITLY user-confirmed night as an auto night. `sleepReviewExtensionTarget` (Sessions.swift:38723) therefore matches it, and both review producers bypass their confirmed-overlap suppression: `isUnsettled` returns `(!overlapsConfirmed || isReviewableExtension) && !dismissed` (Sessions.swift:34126) and the physiological lane guards on `!overlapsConfirmed || extendsConfirmed` (Sessions.swift:34776-34777). Its bar is only endGain >= 30 min plus durationGain >= 20 min. So a longer re-mint of the night the user just saved is "unsettled" again, and the only remaining brake is the tombstone — which is size-ratio keyed and fails as soon as the re-mint grows past ~43% (see B). Only the Adjust->Save path, which mints `user_adjusted_*`, is protected; the plain Confirm button is not.

(B) "if you leave it from saving", and what makes it never stop — the tombstone key is asymmetric on read vs write. Read side: `AtriaDismissedSleepCandidate.suppresses` (Sessions.swift:3603-3610) suppresses only when `overlap / max(dismissedDuration, candidateDuration) >= 0.70`, so a republication more than ~43% longer than the dismissed window is not suppressed at all. Write side: `addDismissedSleepCandidate` (Sessions.swift:39188-39197) calls `removeAll { $0.overlaps(start:end:) }` — ANY overlap (Sessions.swift:3595-3597) — before appending, so the store can never hold both the short and the long representation of one night. Dismissing the long re-mint DELETES the tombstone for the short one and vice versa: the two representations alternate forever.

The producer that supplies the growing window is `physiologicalSleepReviewNightDraftCore` (Sessions.swift:34617). It clusters 5-minute HR bins with median <= rest+4 using a 2-hour gap tolerance over a 36-hour lookback and sets `end = min(newestEnd, last.start + 5 min)` (Sessions.swift:34718-34719) — so its window literally keeps growing every refresh as post-wake quiet bins keep joining the cluster ("another sleep recommendation that keeps on going"). Its id `"sleep-physiology-review-<startEpoch>-<endEpoch>-<source>"` (Sessions.swift:34825) is new on every boundary change. `makeSleepReviewNightForCacheCore` publishes it via `materializePreferredFreshReview()` = aggregateDraft ?? physiologicalDraft (Sessions.swift:34333-34334) exactly when the aggregate lane is settled — i.e. right after the user saves. The other two producers are the aggregate lane (`"sleep-review-<start>-<end>-<source>"`, Sessions.swift:34224) and the daily rollup inside `SleepHistorySnapshot.init` (`"sleep-history-<day>"`, window `(rollup.sleepStart, rollup.sleepEnd)`, Sessions.swift:54304-54334). `AtriaTodaySleepReviewProjectionState.preferredReview` (AtriaOverviewSections.swift:1446-1493) alternates between them and its own constants document the disagreement — `materialOnsetCorrection` 30 min, `maximumSameEpisodeGap` 2 h. So the window the user dismisses is routinely not the window that comes back.

Two corroborating keyings drift the same way. `AtriaPendingSleepReviewStore.load` retires the durable receipt on confirmation only at `overlapFraction >= 0.70` of the RECORD's own duration (AtriaPendingSleepReviewStore.swift:185-192, 254-267), whereas every in-memory lane suppresses on ANY overlap (`sleepWindowsOverlap`, Sessions.swift:38708-38710) — so a receipt persisted for a grown window survives the Save and is re-served to cold-launch/BGTask scheduling via `persistedPendingSleepReviewForNotification` (Sessions.swift:33596-33613). And the notification lane's dismissal gate is dead: `sleepReviewDismissedIDKey` is read at LocalNotificationScheduler.swift:1560 but written nowhere in the repo, while the reminder cap/cooldown are keyed on `latest.id` (LocalNotificationScheduler.swift:1602-1603) which embeds the epoch boundaries, so each re-minted window gets a fresh reminder budget; the surviving `AtriaSleepReviewNotificationDebounce` is keyed on the START minute only (LocalNotificationScheduler.swift:2271-2273), which changes whenever the onset-correcting producer wins.

Not starved by the 4 h stall — this is settlement logic that reproduces from stored evidence. The stall aggravates it: `rangeLossBackfillPending` since 2026-08-06 plus the `history_sequence_gap_replay_mismatch` drain failure mean late evidence keeps arriving in chunks and re-bounding the same night, which is precisely the input that mints new windows. Caveat on scope: I could not read the user's `atria.sleepReview.dismissedWindows.v1` blob, so I cannot say which of (A) or (B) fired on this specific phone; both paths are reachable and neither is covered by a test.

**Evidence**

- Atria/Atria/Sessions.swift:3603-3610 — AtriaDismissedSleepCandidate.suppresses: `overlap / max(dismissedDuration, candidateDuration) >= 0.70`; a re-mint >~43% longer than the dismissed window is not suppressed
- Atria/Atria/Sessions.swift:3595-3597 — AtriaDismissedSleepCandidate.overlaps: ANY overlap (`start < otherEnd && end > otherStart`), the predicate used on the write side
- Atria/Atria/Sessions.swift:39188-39197 — addDismissedSleepCandidate: `dismissedSleepCandidates.removeAll { $0.overlaps(start: start, end: end) }` deletes every ANY-overlapping tombstone before appending the new one, so one night can hold only one window
- Atria/Atria/Sessions.swift:39177-39185 — dismissSleepCandidate(night) tombstones exactly `night.start`/`night.end`, i.e. only the representation currently on screen
- Atria/Atria/Sessions.swift:35098-35099 — confirmSleepHistoryNight: `clearDismissedSleepCandidates(overlappingStart: start, end: end)` then `addDismissedSleepCandidate(start: start, end: end)` — again only the reviewed window
- Atria/Atria/Sessions.swift:35127-35134 — reviewedSleepSource echoes the detector source on Confirm; Sessions.swift:54057-54069 explicitSleepSources contains sleep_candidate / sleep_window / validated_sleep_window
- Atria/Atria/Sessions.swift:38819-38822 and 38793 — isExtendableAutoNight excludes only manual_* / user_adjusted_*, so a user-Confirmed night is still 'auto'
- Atria/Atria/Sessions.swift:38723-38757 — sleepReviewExtensionTarget: minimumEndGain 30 min, minimumDurationGain 20 min, startTolerance 5 min, maximumStartLead 30 min
- Atria/Atria/Sessions.swift:34112-34127 — isUnsettled: `(!overlapsConfirmed || isReviewableExtension) && !dismissed`; the extension exception is the only way past a confirmed record and it fires here
- Atria/Atria/Sessions.swift:34770-34780 — physiological lane guard `!overlapsConfirmed || extendsConfirmed`, then the same `$0.suppresses(start:end:)` check
- Atria/Atria/Sessions.swift:34617 and 34713-34719 — physiologicalSleepReviewNightDraftCore: 5-min bins median <= rest+4, 2-hour gap clustering, 36 h lookback, `end = min(newestEnd, last.start + 5min)` — the window grows every refresh
- Atria/Atria/Sessions.swift:34825 — physiological id `sleep-physiology-review-<start>-<end>-<source>`; Sessions.swift:34224 — aggregate id `sleep-review-<start>-<end>-<source>`; Sessions.swift:54334 — rollup id `sleep-history-<day>`
- Atria/Atria/Sessions.swift:34333-34334 — makeSleepReviewNightForCacheCore ends with materializePreferredFreshReview() = aggregateDraft ?? physiologicalDraft, so the physiological re-mint is published as pendingSleepReviewNightForUI once the aggregate lane is settled
- Atria/Atria/AtriaOverviewSections.swift:1446-1493 — preferredReview alternates between snapshot.latestReviewable (rollup) and pendingSleepReviewNight; materialOnsetCorrection 30 min and maximumSameEpisodeGap 2 h document that the windows disagree
- Atria/Atria/AtriaOverviewSections.swift:765-767 — the Today card's Dismiss is store.dismissSleepCandidate(night) on whichever representation preferredReview chose
- Atria/Atria/AtriaPendingSleepReviewStore.swift:185-192 and 254-267 — durable receipt retired on confirmation only at overlap >= 0.70 of the RECORD's duration, vs ANY overlap everywhere else (Sessions.swift:38708-38710 sleepWindowsOverlap)
- Atria/Atria/Sessions.swift:33596-33613 — persistedPendingSleepReviewForNotification serves that durable receipt to cold-launch/BGTask notification scheduling
- Atria/Atria/LocalNotificationScheduler.swift:43 and 1560 — sleepReviewDismissedIDKey 'atria.sleepReview.dismissedID' is read but grep over Atria/ and AtriaTests/ finds no writer: dead suppression key
- Atria/Atria/LocalNotificationScheduler.swift:1602-1603 — reminder count/cooldown keyed on latest.id (embeds epoch boundaries) so each re-mint gets a fresh budget; LocalNotificationScheduler.swift:2271-2273 — debounce keyed on START minute only
- Atria/AtriaTests/AtriaSleepReviewCacheTests.swift:165-181 — testSleepDismissalRequiresSubstantialCandidateCoverage pins only the small-fragment direction of the 0.70 rule; no test for a materially larger re-mint escaping a full-night dismissal, and none for tombstone erasure
- Atria/AtriaTests/AtriaSleepExtendTests.swift:115-146 — testReviewContinuationNeverReplacesManualOrSeparateSleep covers manual_sleep only; no case pins a user-Confirmed review night
- device dump: offlineSync.rangeLossBackfillPending=true requested 2026-08-06, lastDrainFailure history_sequence_gap_replay_mismatch — late evidence keeps re-bounding the same night, feeding the re-mint loop (aggravator, not cause)

**Proposed fix**

Four changes; (1) and (3) are load-bearing.

1. Atria/Atria/Sessions.swift:39188-39197 — stop destroying overlapping tombstones. Replace `removeAll { $0.overlaps(...) }` + `append` with a UNION merge: collect the overlapping tombstones, remove them, append a single `AtriaDismissedSleepCandidate(start: min(all starts, start), end: max(all ends, end))`. One night then accumulates one growing tombstone covering both the short and the long representation, killing the alternation. Leave `clearDismissedSleepCandidates` (Sessions.swift:39199-39205) as-is — its ANY-overlap un-dismiss on save is deliberate.

2. Atria/Atria/Sessions.swift:3603-3610 — add a same-episode-growth arm to `suppresses` before the existing return: `if overlap / dismissedDuration >= 0.90 && abs(otherStart.timeIntervalSince(start)) <= 30*60 { return true }`. This retires a grown re-mint that shares the dismissed onset without resurrecting the "tiny fragment must not hide a larger night" behavior — the 10-min fragment in the existing test starts 2 h from the night's onset, so it still cannot suppress. Assert that explicitly.

3. Atria/Atria/Sessions.swift:35127-35134 — make an explicit Confirm user-authored: return `"user_confirmed_sleep"` / `"user_confirmed_nap"` instead of echoing the detector source, add them to `explicitSleepSources` (Sessions.swift:54057) / `explicitNapSources` (Sessions.swift:54049), and make `isUserAuthoredSleepSource` (Sessions.swift:38793) match them. `isExtendableAutoNight` (Sessions.swift:38819) then stops treating a settled night as extendable, so `isUnsettled` (Sessions.swift:34126) and the physiological guard (Sessions.swift:34776-34777) fall back to plain ANY-overlap suppression and no second card is published after Save; continuation stays reachable through the Adjust sheet. NOTE this also stops `sleepExtendReplacement` (Sessions.swift:38835) and `sleepReviewInsertionBase` (Sessions.swift:38769) from growing a user-confirmed night — desired, but it changes those two paths and needs its own regression pass. Also check `confirmedSleepIsPhysiologicalMainSleep` and the nap classification still accept the new strings.

4. Atria/Atria/AtriaPendingSleepReviewStore.swift:185-192 — align the confirmation check with `sleepWindowsOverlap`: retire the durable receipt on ANY overlap with a confirmed sleep (`$0.end > record.start && $0.start < record.end`) rather than `overlapFraction >= 0.70`, so a receipt written for a grown window cannot survive a Save and be re-served to the notification lane.

5. Atria/Atria/LocalNotificationScheduler.swift:1560 — the `sleepReviewDismissedIDKey` gate is a no-op (no writer). Replace the id read with a window check against `AtriaDismissedSleepCandidateStore.load()` plus the confirmed-sleep set before scheduling, or delete the key outright and rely on (1)-(4).

**Test plan**

Scheme AtriaTests, pure-static assertions only (the suites share process/defaults, so no multi-save integration tests).

- AtriaTests/AtriaSleepReviewCacheTests.swift, beside testSleepDismissalRequiresSubstantialCandidateCoverage: `testDismissedNightStaysSuppressedWhenTheDetectorRepublishesAGrownWindow` — tombstone 00:30-05:33 (5 h 03, matching the device's notification.sleepEvent.lastDurationMinutes=303), candidate 00:30-08:10 (span ratio 0.66) → `suppresses` must be true. Keep the existing tiny-fragment assertion false in the same test.
- Same file: `testDismissingAGrownRepublicationKeepsTheOriginalWindowSuppressed` — apply the (now merging) tombstone-insert helper twice, short window then long window, and assert BOTH windows are suppressed by the resulting store. Today the first tombstone is silently erased by Sessions.swift:39190.
- AtriaTests/AtriaSleepExtendTests.swift, mirroring testReviewContinuationNeverReplacesManualOrSeparateSleep: `testUserConfirmedReviewNightIsNotAnExtendableAutoNight` — `XCTAssertNil(SessionStore.sleepReviewExtensionTarget(existing: [sleep(source: "user_confirmed_sleep", start: at(0), end: at(7))], candidateStart: at(0), candidateEnd: at(9), candidateDuration: 8.25*60*60, isNap: false))`, plus `XCTAssertTrue(SessionStore.isUserAuthoredSleepSource("user_confirmed_sleep"))` and `XCTAssertFalse(SessionStore.isExtendableAutoNight(<that record>))`. Keep the existing auto_confirmed_sleep continuation case green.
- AtriaTests/AtriaTodaySleepReviewProjectionTests.swift: extend the dismissal test near line 234 so `SessionStore.makeBoundedSleepReviewCacheProjection` returns `main == nil` for a same-onset, 2 h-longer republication of the dismissed window, and separately returns `main == nil` when a confirmed record with source "user_confirmed_sleep" already covers that window.
- Add a source-scan guard in this repo's idiom (cf. testBothAutomaticPersistencePathsHonorDurableDismissals) asserting the sleep-review notification decision consults the dismissal store rather than a defaults key nothing writes.

**Noticed nearby**

1. DEAD SUPPRESSION KEY: `sleepReviewDismissedIDKey` = "atria.sleepReview.dismissedID" is declared at Atria/Atria/LocalNotificationScheduler.swift:43 and read at :1560 as the "user dismissed this candidate" gate for the sleep-review push, but a grep across Atria/ and AtriaTests/ finds no writer anywhere. That gate has never been able to fire. Directly relevant to field-report item 11.

2. Atria/Atria/Sessions.swift:32429-32442 `activityDetectionsForUI` filters ONLY `.workout` and `.activityCandidate` against the workout tombstone store; its `guard ... else { return true }` returns every other kind — including `.sleepCandidate` and `.restCandidate` — unconditionally, honoring no sleep dismissal or confirmation. Harmless today only because AtriaActivityMonitor.swift:305-323 `visibleDetections` re-filters to those same two kinds. Latent trap the moment a sleep detection is rendered from that list.

3. The nap lane (`makeNapReviewNightsForCacheCore`, Sessions.swift:34365-34412) uses a stricter rule than the main lane — plain `!overlapsConfirmed && !dismissed`, no extension exception — so naps cannot resurface via (A), but they inherit the same `suppresses` ratio key and the same tombstone-erasure bug from `addDismissedSleepCandidate`. Relevant to item 6.

4. Storage (item 12): `historical-archive.manifest.json` declares rotationThresholdBytes = 134217728 (128 MB) while raw segments actually rotate at 32 MB — manifest and writer disagree, and 686 uncompressed raw-*.jsonl files (2986 MB) are never pruned.

**Challenger 1 — refuted=False**

I read every cited file:line on branch codex/whoop-remaining-product-gaps (HEAD 47538c32). The core mechanism holds — I could not refute (A) or (B) — but four supporting claims and three of the five proposed fixes are wrong or insufficient.

CONFIRMED BY READING THE CODE

(A) Confirm does not make a night user-authored.
- `reviewedSleepSource` (Sessions.swift:35127-35134) echoes `night.source` when it is in `explicitSleepSources`, else "sleep_window". The physiological card's source is `sleep_episode_review` (Sessions.swift:34782), which is NOT in `explicitSleepSources` (Sessions.swift:54056-54070), so it lands on "sleep_window" — which IS in the set, so `confirmedSleepSourceIsNap` returns false (Sessions.swift:40178-40186) and `isExtendableAutoNight` (Sessions.swift:38819-38822) returns true, because `isUserAuthoredSleepSource` (Sessions.swift:38793) matches only `manual_` / `user_adjusted_`. Verified.
- `isUnsettled` at Sessions.swift:34126 is exactly `(!overlapsConfirmed || isReviewableExtension) && !dismissed`; the physiological guard at 34776-34780 is `!overlapsConfirmed || extendsConfirmed` plus the same `suppresses` test. Verified.
- `confirmSleepHistoryNight` writes the tombstone for the reviewed window only (Sessions.swift:35098-35099), and the confirmed record's start can be pulled earlier to `min(start, extensionTarget.start)` (Sessions.swift:34999) while the tombstone keeps the un-extended `start` — a second, smaller asymmetry the claim did not name.
- Test gap confirmed: `confirmedSleep(overlapping:)` in AtriaSleepReviewCacheTests.swift:97-117 uses source "manual_sleep", and AtriaSleepExtendTests.swift:116-146 covers only `manual_sleep` / `auto_confirmed_sleep`. Nothing pins a detector-sourced, user-Confirmed night.

(B) The tombstone key really is asymmetric, and the write side really is destructive.
- `suppresses` divides by `max(dismissedDuration, candidateDuration)` (Sessions.swift:3603-3610); `overlaps` is ANY overlap (3595-3597); `addDismissedSleepCandidate` does `removeAll { $0.overlaps(...) }` then appends (Sessions.swift:39189-39190). One night can hold exactly one window. Verified.

The growing producer is real and has no upper bound.
- `physiologicalSleepReviewNightDraftCore` (Sessions.swift:34617) clusters 5-min bins with median <= rest+4 at 2 h gap tolerance over a 36 h lookback and sets `end = min(newestEnd, last.start + 5 min)` (34718-34719). The `mainSleep` admission at 34734-34739 has a FLOOR (captured >= 150 min, span >= 3 h,

_Corrections:_ The core mechanism survives; four supporting claims and three of five fixes do not.

CORRECTED ROOT CAUSE

There are TWO distinct settlement failures, not one, and the report merges them:

(A) Post-Confirm resurfacing (needs no tombstone alternation). `reviewedSleepSource` (Sessions.swift:35127-35134) never mints a user-authored source, so `isExtendableAutoNight` (38819-38822) still calls an explicitly Confirmed night "auto". Both remaining review lanes — aggregate `isUnsettled` (34126) and physiological (34776-34777) — carry an extension exception past `overlapsConfirmed`. The daily rollup lane is NOT a producer here: it bails on ANY confirmed overlap (54306-54329). The tombstone written at Confirm (35098-35099) is the only brake, and it is `max()`-keyed (3603-3610), so it fails once the re-mint exceeds ~1.43x. `physiologicalSleepReviewNightDraftCore` supplies that growth and has a floor but NO CEILING on episode length (34734-34739 with `end = min(newestEnd, last.start + 5 min)` at 34718-34719), so a night+morning cluster clears 1.43x easily. Extra asymmetry the report missed: the confirmed record's start can be pulled back to `min(start, extensionTarget.start)` (34999) while the tombstone keeps the un-extended start.

(B) Dismiss-only alternation (no confirmed record exists). Here the rollup lane IS live, and it and the physiological lane describe the same night at windows differing by >43%. `addDismissedSleepCandidate` destroys every ANY-overlapping tombstone before appending (39189-39190), so the store holds one window and the two representations swap forever.

FACTUALLY WRONG IN THE CLAIM

1. "A receipt persisted for a grown window survives the Save." It does not. `addDismissedSleepCandidate` calls `AtriaPendingSleepReviewStore.clear(overlappingStart:end:)` (Sessions.swift:39193-39196) and `clear` retires on ANY overlap (AtriaPendingSleepReviewStore.swift:216-224); Confirm reaches it at 35099, the already-confirmed repair at 35009, Dismiss at 39179. Fix 4 is u

**Challenger 2 — refuted=False**

I read the code myself and arrived at the same core mechanism, so I am NOT refuting: settlement (Confirm/Dismiss) is recorded against exactly one time window, while several independent producers re-describe the same night with materially different windows, and the suppression predicate that is supposed to retire them tolerates >~43% disagreement. Their half (B) is the load-bearing, provably non-terminating defect and I confirmed every line. Half (A) is real code but I reweight it (see corrections), and one of their corroborating claims is wrong. I also found two things they missed that make the account concrete and complete.

VERIFIED EXACTLY AS THEY STATE
- `AtriaDismissedSleepCandidate.suppresses` Sessions.swift:3603-3610 — `overlap / max(dismissedDuration, candidateDuration) >= 0.70`. Because it normalizes by `max`, it is SYMMETRIC: if window A escapes a tombstone for B, then B escapes a tombstone for A. That symmetry is what makes the loop provably non-terminating, and neither investigator's report states it explicitly.
- `addDismissedSleepCandidate` Sessions.swift:39188-39197 — `removeAll { $0.overlaps(...) }` (ANY overlap, `overlaps` at 3595-3597) before appending. It is the ONLY writer of the tombstone store, so the store structurally cannot hold two overlapping representations of one night. Dismissing the long window deletes the short window's tombstone and vice versa.
- Worked example with real code constants: rollup window 23:00–04:00 (5h), physiological window 00:30–07:00 (6.5h) → overlap 3.5h / max 6.5h = 0.538 < 0.70 in BOTH directions → each escapes the other's tombstone, and each dismissal erases the other's tombstone. Infinite alternation, exactly "another sleep recommendation keeps on going".
- The three producers and their throwaway ids: aggregate `"sleep-review-<start>-<end>-<source>"` Sessions.swift:34224; physiological `"sleep-physiology-review-<start>-<end>-<source>"` Sessions.swift:34826; daily rollup `"sleep-history-<day>"` Sessions.swift:54334. Selection alternates between them at Sessions.swift:34282-34331 (`snapshot.latest` branch → `preferredGrowingSleepReview`) and 34333-34334 (`materializePreferredFreshReview` = aggregate ?? physiological).
- Physiological window genuinely grows: `end = min(newestEnd, last.start + 5 min)` Sessions.swift:34718-34719, clustering 5-min bins with median <= rest+4 over a 36h lookback with a 2h gap tolerance (34697-34703). `newestEnd` is the newest session end, so on a sedentary evening the "sleep" 

_Corrections:_ Same root cause, but three corrections and two additions.

1) ADDITION — the missing third window producer, and why THIS user's data arms the loop. The rollup lane's window is built at Sessions.swift:43912-43913:
   let sleepStart = aggregateSleep?.start ?? sleepDetections.map(\.start).min()
   let sleepEnd   = aggregateSleep?.end   ?? sleepDetections.map(\.end).max()
When the aggregate detector produces nothing for the day — exactly the HR-only, gap-riddled days this phone has (rangeLossBackfillPending since 2026-08-06, history_sequence_gap_replay_mismatch, 4h silence) — the rollup window silently becomes the UNION SPAN of every single-session sleep detection on that civil day, min-start to max-end. That is systematically far wider than the physiological cluster, which is precisely what drops the overlap ratio below 0.70 and arms the ping-pong. The other investigator listed the rollup lane but treated its window as `(rollup.sleepStart, rollup.sleepEnd)` without noticing it degrades to a union span. This is the concrete reason the disagreement on this device is >43% rather than the ~30 min the code's own constants anticipate.

2) ADDITION — a fourth instance of the same keying disagreement, and the one that best matches "keeps on going" after Save: the projection continuity hold, `preservingRealReviewAcrossTransientLoss` (AtriaOverviewSections.swift:1512-1546). It re-publishes the previously shown review whenever the incoming projection is nil, and it is SELF-PERPETUATING because `refresh` feeds it `previous: latestState`, where `latestState` is itself the held output (AtriaOverviewSections.swift:1625-1633). Its release conditions are the same loose keying: `overlap / priorDuration >= 0.70` against confirmed nights (1531-1538) and `suppresses` against tombstones (1524-1526), while Confirm settles only the exact displayed window. So whenever the saved window covers less than 70% of the held review's span, the card is re-pinned on every refresh for up to 72h (`maximum


---

### Item 6 — real-defect (refuted 0/2, confidence high)

**Root cause**

Two nap producers exist; commit e9ccf347 (2026-07-22, "Checkpoint Atria reliability and history recovery") disabled both, and on this strap neither can ever re-open.

PRIMARY (explains "100% not working" for every nap, any time of day): Sessions.swift:45176 `let napCandidateReady = napPhysiologyReady && motionValidated`, enforced by the fail-closed drop at Sessions.swift:45256-45259 (`if napPhysiologyReady && !napCandidateReady { return nil }`). A window with correct nap physiology AND correct nap clock shape is discarded entirely — no row, no diagnostic row, nothing rendered — unless validated low-motion evidence covers it. `motionValidated` (Sessions.swift:45174-45175) can only come from (a) recovered motion epochs needing >=80% validated coverage with <=90 s max gap (Sessions.swift:45508-45512), or (b) HistoricalArchive.MotionFeatureSummary.lowMotionReady needing >=300 validated rows, >=0.95 validated ratio, >=30 min coverage, <=5 min max gap (HistoricalArchive.swift:482-489), which is also the sole source of SavedSession.motionEvidenceValidated (AtriaBLEManager.swift:42652 `let motionEvidenceValidated = historicalIMU?.lowMotionReady ?? false`). This device has run pure-HR since mid-July (atria.protocol.imuFrames=0, atria.motionHandshake.lastR10At=2026-07-14 19:07, atria.protectedR10.cleanOwner='pure_hr_v8', streamSuppressed=true) and the only motion it banks is duty-cycled ~2-minute glances, so the gate is structurally unsatisfiable — not merely stalled.

SECONDARY, independent, and decisive for the specific 2026-08-18 evening nap: Sessions.swift:44961-44963 `clusterDaytimeNapWindow = !clusterOvernightReviewWindow && clusterStartHour >= 11 && clusterEndHour <= 20`. The nap ends at hour 21, so clusterDaytimeNapWindow=false -> daytimeNapCandidateReady/shortLowHRNapCandidateReady false (44964-44972) -> napPhysiologyReady false (44980). With totalDuration 2 h 14 m it also misses strictDurationReady (3 h), fragmentedFallbackReady (needs cluster.count>1 + 3 h span), denseMorningHROnlyReviewReady (denseReviewClockWindow only allows starts 03-08 or 08-13, Sessions.swift:45015-45019) and denseLongHROnlyReviewReady (needs 5 h), so the whole cluster is returned nil at the guard Sessions.swift:45067-45071. The physiology-bin fallback cannot rescue it either: `let nap = false` (Sessions.swift:34769) killed its nap arm, and shiftedDaytimeReview needs captured >= 150 min and span >= 3 h (Sessions.swift:34747-34751), which 2 h 14 m fails.

This is NOT starvation by the 4 h HR blackout: the blackout began 21:56:32, after the nap window closed at 21:42:50, and offlineSync.drainedThroughUnix already reached 21:22:38, so the nap's HR was on-phone. The pattern predates the stall by four weeks.

**Evidence**

- Sessions.swift:45176 — `let napCandidateReady = napPhysiologyReady && motionValidated` (the motion requirement)
- Sessions.swift:45256-45259 — `if napPhysiologyReady && !napCandidateReady { // Fail closed ... return nil }` (silent total drop, no visible fail-closed state)
- Sessions.swift:44958-44963 — `clusterOvernightReviewWindow`/`clusterDaytimeNapWindow`; `clusterEndHour <= 20` excludes every nap ending at or after 21:00
- Sessions.swift:44964-44972 — daytimeNapCandidateReady / shortLowHRNapCandidateReady both require clusterDaytimeNapWindow
- Sessions.swift:45067-45071 — the guard that returns nil when napPhysiologyReady and all main-sleep tiers are false
- Sessions.swift:5037-5038 — napMinimumDuration 20 min, napMaximumSpan 3 h (a true 3 h nap with any lead-in is out of span)
- Sessions.swift:34769 — `let nap = false` in the 5-minute physiology-bin fallback; Sessions.swift:34776 `guard mainSleep || shiftedDaytimeReview || nap` and 34782 `? "sleep_episode_review" : "nap_candidate"` are now dead nap arms
- Sessions.swift:34747-34751 — shiftedDaytimeReview needs captured >= 150 min AND span >= 3 h, so a 2 h 14 m evening nap cannot surface as a shifted sleep either
- Sessions.swift:34341-34345 + 34482 — docstring promises "HR-only naps (no validated motion) still surface ... review_needed" and the code has a `motionEvidenceValidated ? confidence : "review_needed"` branch, but the producer never emits an HR-only nap, so that branch is unreachable (honesty-rule violation: documented behavior does not exist)
- HistoricalArchive.swift:482-489 — MotionFeatureSummary.lowMotionReady thresholds (>=300 validated rows, >=0.95 ratio, >=30 min coverage, <=5 min gap, stillness>=0.72, intensity<=0.18)
- Sessions.swift:45508-45512 — recovered-epoch path: sufficient requires validatedFraction >= 0.80 and maximumGap <= 90 s across the whole nap window
- AtriaBLEManager.swift:42652 — `let motionEvidenceValidated = historicalIMU?.lowMotionReady ?? false` (only motion source for a saved session)
- git: `git log -S "let nap = false"` and `-S "napCandidateReady = napPhysiologyReady && motionValidated"` both -> e9ccf347, 2026-07-22 17:41 +0530; its diff shows `-let nap = !mainSleep` / `+let nap = false` and `-let napCandidateReady = daytimeNapCandidateReady || shortLowHRNapCandidateReady` / `+... && motionValidated` plus the added fail-closed return
- device defaults (pull/com.adidshaft.atria.plist): last auto nap reviews ever scheduled are `atria.notification.sleepReview.*.sleep-physiology-review-1784534100-1784537700-nap_candidate` = 2026-07-20 13:25-14:25 and `...-1784345700-1784346900-nap_candidate` = 2026-07-18 09:05 — i.e. the last automatic nap on this phone is 2 days before e9ccf347, and none since
- device defaults: atria.confirmedSleeps.v1 — every nap after that date is hand-entered: `user_adjusted_nap` 2026-08-08 15:25-16:40 and `manual_nap` 2026-08-17 14:46-17:24 (2.63 h, startHour 14, endHour 17, span < 3 h = textbook napPhysiologyReady) — that one is inside the clock window, so only the motionValidated gate can explain it
- device defaults: atria.protocol.imuFrames=0; atria.motionHandshake.lastR10At=2026-07-14 19:07:15; atria.protectedR10.cleanOwner='pure_hr_v8'; atria.protectedR10.streamSuppressed=True; atria.gate4.historicalIMU.status='window_complete_requesting_offload' stuck since 2026-07-27 00:40 with onSequence=0
- device defaults: atria.workoutHistoricalMotionBank.coverage.v2 = 512 closed windows spanning 08-13..08-18, all ~2 min (08-18: 15:21, 16:09, 16:50, 17:56, then nothing until 21:05) — zero motion coverage across the entire 19:28-21:42 nap, and never the 30 min contiguous coverage lowMotionReady demands; atria.workoutHistoricalMotionBank.enabled=False
- device evidence: activeJournal.lastClose 2026-08-18 21:42:50, label 'All-day wear', duration 8078 s -> window 19:28:12-21:42:50 (endHour 21, 2 h 14 m); offlineSync.drainedThroughUnix.v1 = 21:22:38 (HR for the nap was already on-phone before the 21:56:32 blackout)
- Atria/AtriaTests/AtriaSleepReviewCacheTests.swift:284-303, 335-372 — every producer test passes `validatedMotion: true`; the only HR-only nap test (line 305-332) hand-builds a Night and never calls the producer, which is why the regression shipped green

**Proposed fix**

Two changes, both review-only (no auto-confirm path touched), plus one honesty fix.

1) Sessions.swift:45176 — stop making a nap unrepresentable when the strap has no motion channel. Replace
   `let napCandidateReady = napPhysiologyReady && motionValidated`
   with a tiered admission:
   `let hrOnlyNapSpecific = !motionValidated && motionSource == "unavailable"/historicalMotion.rows == 0 && cluster.count <= 2 && avg <= rest + 8 && medianHR <= rest + 6 && hrP90 <= rest + 20 && peak <= rest + 25 && elevatedSampleFraction < 0.02 && hrObservedCoverageFraction >= 0.80 && maximumHRSampleGap <= 10 * 60 && qualifiedRRCoverageFraction >= 0.60`
   `let napCandidateReady = napPhysiologyReady && (motionValidated || hrOnlyNapSpecific)`
   Then delete the fail-closed `return nil` at Sessions.swift:45256-45259 and give the HR-only arm its own reason string ("HR-only nap candidate; strap motion channel unavailable; user confirmation required"). This preserves what e9ccf347 was protecting: the 2026-07-22 false nap peaked at 105 bpm (~rest+43) and would still be rejected by `peak <= rest + 25` / `elevatedSampleFraction < 0.02`. `confidence` stays `.low` (Sessions.swift:45188), so the row renders as "Possible nap" (AtriaOverviewSections.swift:1116-1118) and the existing `"review_needed"` branch at Sessions.swift:34482 finally becomes live — never counted toward sleep need until the user confirms.

2) Sessions.swift:44961-44963 — widen the nap clock window so an evening nap exists at all:
   `let clusterDaytimeNapWindow = !clusterOvernightReviewWindow && clusterStartHour >= 11 && clusterEndHour <= 22`
   (keep `!clusterOvernightReviewWindow` so a 20:00-start episode still routes to the overnight tier). Mirror the same bound at the session-eligibility site Sessions.swift:44686 and at the diagnostics counter Sessions.swift:46378 so the three stay consistent. Optionally raise `napMaximumSpan` (Sessions.swift:5038) from 3 h to 3.5 h so a genuine "2-3 h" nap with a short awake lead-in is not cut by span.

3) Honesty: delete or correct the now-false docstring at Sessions.swift:34341-34345, and remove the dead nap arms left by `let nap = false` (Sessions.swift:34769, 34776, 34782) so the physiology fallback no longer claims a nap path it cannot take.

Do NOT relax anything in the auto-confirm predicates — naps remain review-only rows that never auto-confirm (Sessions.swift:34483-34486 already sets `confirmed: false`).

**Test plan**

Add to Atria/AtriaTests/AtriaSleepReviewCacheTests.swift (scheme AtriaTests), reusing its `daytimeLowHRSession(start:validatedMotion:)` / `date(day:hour:)` helpers and driving the real producer `SessionStore.makeNapReviewNightsForCache`:

1. `testHROnlyDaytimeNapSurfacesAsReviewRowWhenMotionUnavailable` — `daytimeLowHRSession(start: date(day: 17, hour: 14), validatedMotion: false)` with dense RR; assert exactly one row, `source == "nap_candidate"`, `confidence == "review_needed"`, `confirmed == false`, `motionValidated == false`. This is the regression pin for Sessions.swift:45256 and reproduces the 2026-08-17 14:46-17:24 nap the user had to enter by hand.

2. `testEveningNapEndingAfterEightPMSurfacesAsNapReview` — single low-HR session 19:28 -> 21:42 (8078 s, matching the device journal), motion absent; assert one nap row. Pins Sessions.swift:44963 (`clusterEndHour <= 20`). Should fail on today's code.

3. `testAmbiguousDaytimeLowHRWithExertionPeakStaysSuppressed` — the physical 2026-07-22 false-nap shape (mostly rest+4 bins but a 105 bpm peak, elevated fraction ~0.10); assert `rows.isEmpty`. Keeps e9ccf347's anti-false-positive contract intact under the new HR-only arm.

4. `testHROnlyNapNeverAutoConfirms` — feed the same HR-only nap through the save/auto-confirm path and assert it stays unconfirmed and contributes no sleep-need credit.

5. Re-run the existing motion-validated nap tests (AtriaSleepReviewCacheTests.swift:284-372) unchanged — they must stay green — plus the AtriaSleepStageIntegrity / settlement suites for the shared `aggregateSleepCandidatesCore` return-nil change. Note the known repo gotchas: use scheme AtriaTests, and keep fixture time bases inside the daytime/evening windows since these suites share process defaults.

**Noticed nearby**

1. Same root cause starves item 10 (sleep stages) and contributes to item 7 (steps): the strap has produced no IMU since 2026-07-14 (atria.protocol.imuFrames=0, protectedR10.streamSuppressed=true, cleanOwner='pure_hr_v8'), and atria.gate4.historicalIMU has been stuck at 'window_complete_requesting_offload' with onSequence=0 since 2026-07-27 — a three-week-old offload request that never completed. Every motion-gated feature is silently dark, and nothing in the UI says "this strap is not sending motion".
2. atria.debug.motionBankDutyCycle.yesterday.v1 for 2026-08-18 shows `sync_cutover: 75060 s` — 20.8 of 24 hours the motion bank yielded to history sync, plus `await_fresh_hr: 4507 s`, and `atria.workoutHistoricalMotionBank.enabled = False`. Even the 2-minute motion glances are being crowded out by the history-drain backlog, so fixing the drain (items 2/12) would not by itself restore nap detection.
3. Dead code left by e9ccf347: with `let nap = false` (Sessions.swift:34769), the `|| nap` in the guard at 34776 and the `: "nap_candidate"` arm of the source ternary at 34782 can never be taken; likewise `confidence: candidate.motionEvidenceValidated ? ... : "review_needed"` at 34482 is unreachable. The nap docstring at 34341-34345 documents behavior that no longer exists.
4. Test-coverage hole that let this ship: every producer-level nap test passes `validatedMotion: true`; the one "HR-only nap" test (AtriaSleepReviewCacheTests.swift:305-332) hand-constructs a `Night` and asserts only presentation, so it stayed green while the producer stopped emitting HR-only naps entirely.
5. The last admission receipt (atria.debug.sleepReviewAdmissionReceipts.v1, 2026-08-19 01:37:47, frontier 21:22:38) reads `gateResult=review_builder_gate, finalOutcome=not_qualified(review_builder_gate)` — the settlement pass did run after the nap and produced a terminal receipt, confirming the pipeline was alive and the builder simply refused the window. That is the receipt trail proving "not starved".

**Challenger 1 — refuted=False**

I could confirm the mechanism by reading real code, so the claim stands. Every cited file:line says what the claim says it says, control flow reaches it, and no guard, earlier return, alternate producer, or shipped mitigation rescues it.

Verified independently:
- Sessions.swift:45176 is exactly `let napCandidateReady = napPhysiologyReady && motionValidated`; motionValidated (45173-45175) is `recoveredMotion.hasRecoveredEpochs ? recoveredMotion.lowMotionValidated : (historicalMotion.lowMotionReady || sessionMotionValidated)`. HistoricalArchive.swift:481-489 lowMotionReady thresholds match (>=300 validated rows, ratio >=0.95, >=30 min coverage, <=5 min gap, stillness >=0.72, intensity <=0.18), 45508-45512 recovered-epoch sufficiency matches (>=0.80 validated fraction, <=90 s gap), and AtriaBLEManager.swift:42652 is the sole source of SavedSession.motionEvidenceValidated. On a strap banking only ~2-minute duty-cycled glances none of these can be met, so the gate is structurally unsatisfiable, not stalled.
- Sessions.swift:45349 passes `motionEvidenceValidated: motionValidated` into the candidate, so a "nap_candidate" always carries motionEvidenceValidated == true. That makes the `candidate.motionEvidenceValidated ? confidence : "review_needed"` branch at 34482 provably unreachable and the docstring at 34341-34345 ("HR-only naps ... still surface ... review_needed") false as written. Real honesty defect.
- Sessions.swift:34769 `let nap = false` is real; because the guard at 34776 requires `mainSleep || shiftedDaytimeReview || nap`, passing it implies the source ternary at 34782 always yields "sleep_episode_review". The nap arm is dead. shiftedDaytimeReview (34747-34751) needs captured >= 150 min and span >= 3 h, which 2 h 14 m fails.
- git log -S on both strings returns only e9ccf347 (Wed Jul 22 17:41:33 2026 +0530); its diff shows `-let nap = !mainSleep`/`+let nap = false` and `-let napCandidateReady = daytimeNapCandidateReady || shortLowHRNapCandidateReady`/`+let napCandidateReady = napPhysiologyReady && motionValidated` plus the added fail-closed return. No commit after it reopens either path.
- No second producer: `nap_candidate` appears in no non-test file outside Sessions.swift. The resumed-sleep producer (46037) requires a same-day main candidate with separation <= resumedSleepMaximumSeparationFromMain (8 h, line 5092), so a 19:28 start cannot attach to a morning main sleep. Nap rows are wired to the UI (AtriaActivityMonitor.swift:594/604 napReviewCand

_Corrections:_ The root cause is confirmed, but six details are wrong or under-stated, and the fix as written does not compile.

1) WRONG DROP POINT. For a 2-3 h nap the candidate is already nil at the guard Sessions.swift:45243-45250, not at the fail-closed `return nil` at 45256-45259. When napPhysiologyReady && !motionValidated, every other disjunct there is unsatisfiable at nap dimensions: motionValidatedMainSleepReady needs motionValidated; stableHROnlyMainSleepReady needs minimumHROnlyMainSleepReviewDuration = 5 h (Sessions.swift:5067); highSpecificityFragmented needs 5 h + 3 fragments; degradedHROnly needs duration >= 3 h while napMaximumSpan caps span at 3 h; denseMorning/denseLong both require `!napPhysiologyReady` (45020, 45045). The 45256 fail-closed is effectively dead code, reachable only at duration == span == exactly 3 h. So "delete the fail-closed return" is a no-op; the only load-bearing edit is `napCandidateReady` itself.

2) THE FIX DOES NOT COMPILE. `motionSource` is declared at Sessions.swift:45177, one line AFTER the proposed use at 45176. Use `historicalMotion.rows == 0 && !recoveredMotion.hasRecoveredEpochs && motionHintCount == 0`, or hoist the `motionSource` let above `napCandidateReady`. (`historicalMotion.rows` does exist — HistoricalArchive.swift:138.)

3) THE 44686 MIRROR IS UNNECESSARY AND MISDIAGNOSED. The 19:28-21:42 session is NOT dropped by the eligibility pre-filter: line 44755 admits it via `|| shortLowHRNapLike`, which (unlike `napLike`) is not gated on `daytimeNapWindow`. Control flow does reach the cluster classifier; 44961 is the sole binding clock gate. Changing 44686 alters nothing for this case, and 46378 is a diagnostics counter only.

4) `clusterEndHour <= 20` IS NOT FROM e9ccf347. `git log -S "clusterEndHour <= 20"` returns f5060d86, "Detect short nap sleep candidates", Sat Jun 27 08:50:41 2026 — four weeks before the disablement. The evening-nap exclusion is original design, not part of the regression. Only the motion gate and `let na

**Challenger 2 — refuted=False**

I read the code independently and every load-bearing citation checks out, including the git attribution.

VERIFIED FACTS

1. `napCandidateReady = napPhysiologyReady && motionValidated` — Sessions.swift:45176. Confirmed verbatim. `git blame` puts it on e9ccf347 (2026-07-22, "Checkpoint Atria reliability and history recovery").
2. Fail-closed drop — Sessions.swift:45256-45259: `if napPhysiologyReady && !napCandidateReady { ... return nil }`. Confirmed. A window with correct nap physiology AND correct nap clock shape is discarded with no row.
3. `motionValidated` sources — Sessions.swift:45173-45175. Route (a) recovered epochs: `cooperativeRecoveredMotionSleepProvenance` Sessions.swift:45506-45511 requires duration ≥20 min, validatedFraction ≥0.80, maxGap ≤90 s, intensityCount >0, AND lowMotionFraction ≥0.72 with meanIntensity ≤0.18. Route (b) `MotionFeatureSummary.lowMotionReady` HistoricalArchive.swift:482-490 requires ≥300 validated rows, ratio ≥0.95, ≥30 min coverage, ≤5 min gap, stillness ≥0.72, intensity ≤0.18. Route (b) is also the sole source of `SavedSession.motionEvidenceValidated` — AtriaBLEManager.swift:42652 `let motionEvidenceValidated = historicalIMU?.lowMotionReady ?? false`. Confirmed.
4. `clusterDaytimeNapWindow` — Sessions.swift:44961-44963, and `napPhysiologyReady` at 44980. Confirmed, with both `daytimeNapCandidateReady` (44964-44966) and `shortLowHRNapCandidateReady` (44967-44972) requiring it.
5. Guard that drops the whole cluster — Sessions.swift:45067-45071. Confirmed; `strictMinimumDuration` = 3 h (5039), `fragmentedMinimumDuration` = 2.5 h + span 3 h (5054-5055), `minimumAutoConfirmMainSleepDuration` = 5 h (5060), `denseReviewClockWindow` = starts 03-08 or 08-13 only (45014-45019).
6. `let nap = false` — Sessions.swift:34769, blame = e9ccf347. With the guard at 34771-34776 requiring `mainSleep || shiftedDaytimeReview || nap`, the `"nap_candidate"` source assignment at 34778 is unreachable. `shiftedDaytimeReview` (34747-34751) needs captured ≥150 min AND span ≥3 h. Confirmed dead.
7. Exhaustive grep confirms `kind == "nap_candidate"` has exactly these two producers; every other `nap` hit is user-adjust (41518, 39232), presentation, or manual-entry.

DECISIVE INDEPENDENT CORROBORATION they did not cite: the motion requirement is a deliberately pinned invariant, not an accident. Atria/AtriaTests/AtriaSleepAuditRegressionTests.swift:1653-1660 `testDaytimeLowHRWithoutValidatedStillnessDoesNotBecomeNap` asserts `candidates([quietDaytime])

_Corrections:_ Their mechanism stands. Five refinements, one framing correction, one unverifiable claim.

A. THE EVENING EXCLUSION IS TWO-SIDED, not just `endHour <= 20`. Sessions.swift:44958-44960 `clusterOvernightReviewWindow = clusterStartHour >= 20 || clusterStartHour <= 5 || clusterEndHour <= 11`, and 44961 negates it. So a 2-3 h sleep is excluded from the nap window if it STARTS at 20:00+ *or* ENDS at 21:00+. That creates a hard dead zone: a 2-3 h sleep touching 20:00-21:00 is neither a daytime nap (44961-44963) nor an overnight review (needs ≥3 h at 45067, or the 3-8/8-13 dense clock windows at 45014-45019), so it is returned nil and leaves no trace. The 19:28-21:42 window implied by `activeJournal.lastClose` (21:42:50, duration 8078 s = 2 h 14 m) sits exactly in that dead zone.

B. EXACT GATE, ordered by evaluation for this specific nap:
   1. Sessions.swift:44961-44963 → `clusterDaytimeNapWindow = false` (end hour 21 > 20) → Sessions.swift:44980 `napPhysiologyReady = false`.
   2. Sessions.swift:45067-45071 → `return nil`, since 2 h 14 m < 3 h strict, fails fragmented (needs count>1 + 3 h span + 2.5 h), fails both dense tiers.
   For ANY nap that does land in 11:00-20:00 the rejection instead lands at Sessions.swift:45176 → Sessions.swift:45256-45259.

C. THIRD SUPPRESSOR THEY MISSED — one-card review contract with naps ranked last. `sleepCandidateMainSleepRank` (Sessions.swift:20832-20841) assigns `nap_candidate` rank 1, the lowest of all kinds; `preferredSleepCandidateForReview` (Sessions.swift:20767-20774) returns exactly ONE candidate, from the newest day only. `aggregateSleepDay` gives a 19:28-21:42 window day = 2026-08-18, the same day as that morning's main sleep (`notification.sleepEvent.lastDay=2026-08-18`, 303 min). So even in a counterfactual where motion validated, the nap is queued behind the night's main-sleep card and behind any `resumed_sleep_candidate` (rank 2), surfacing only after the main window is settled (Sessions.swift:34128-34172). This is a third 


---

### Item 7 — real-defect (refuted 0/2, confidence high)

**Root cause**

The step *engine* is behaving as designed (a lower bound over the fraction of the wake window the 0x69 motion bank was armed AND the cadence model qualified), but every in-app surface strips the lower-bound grammar and then grades that lower bound as if it were a whole-day total. Three concrete mechanisms, in order of how loudly they say "steps are broken":

(1) The value line drops the "≥". `AtriaDailyStepPresentation.valueText` (Atria/Atria/AtriaDailyStepPresentation.swift:165-176) deliberately returns a bare "\(count)" for `(.verifiedCanonical, .partial)` — the comment at :166-169 says the qualifier was moved to detailText/accessibilityText. `detailText` for that same case (:187-205) was then changed on 2026-08-12 to "Counted through 9:22 PM" with the coverage percent removed on purpose (:188-200). So the ONLY visible statement that the number is partial is a timestamp. The coverage percent survives only in `accessibilityText` (:257-264, "At least N steps, motion tracked for X percent of your day") — VoiceOver only. The repo's own pinned test proves the shape: a day with 11,598 covered / 43,626 missing seconds and 176 steps renders as the string "176" (Atria/AtriaTests/AtriaDailyStepPresentationTests.swift:113-137). Meanwhile the widget the same snapshot feeds DOES render "≥176" (Atria/AtriaWidget/AtriaWidget.swift:137-147). App and widget disagree; the app is the dishonest one.

(2) The "This week" chart in the Strap steps sheet grades those lower bounds red. `AtriaStepsWeekChart.barTint` (Atria/Atria/AtriaStepsWeekChart.swift:25-31) paints a bar red when steps < 50% of goal, amber < 100%, green ≥ 100% — and its own doc comment at :24 concedes "Bars are still verified LOWER BOUNDS". Because banked+qualified coverage is a small fraction of the day (device-definitive ~6-21% in HR-only radio mode), essentially every bar is red. Worse, `loadWeekSteps` (Atria/Atria/AtriaOverviewSections.swift:6479-6491) maps `receipt.steps` with no filter, so (a) a receipt with `motionTicks > 0 && steps == 0` becomes `map[day] = 0` and Swift Charts draws a bar annotated "0" — directly violating the chart's own contract at AtriaStepsWeekChart.swift:5-7 ("missing ≠ zero, never a zero-height bar implying '0 steps recorded'") — and (b) the still-open current-cycle receipt is charted as a completed day even though the doc comment at :22-23 asserts "here every bar is a COMPLETED day". A week of red bars labelled 176 / 412 / 0 is exactly "feels like they aren't working at all".

(3) The day value can collapse to "--" and stick there. When the gravity/cadence model qualifies no run, `estimateCoveredActivityFragments` returns nil (Atria/Atria/AtriaWhoop4MotionTickStepModel.swift:1854), so the compact projection publishes `steps: 0` with `qualifiedSeconds` driven to 0 (Atria/Atria/AtriaWhoop4MotionTickCompactStore.swift:2020-2048). `stepDay` then sets `unresolvedObservedMotion` and zeroes published coverage (Atria/Atria/AtriaWhoop4MotionTickDailyStore.swift:735-744). `AtriaDailyStepPresentation.resolve` excludes that row from the partial lane (:380-382 requires `knownCoverageSeconds > 0`), matches `hasUnresolvedMotionReceipt` (:390-394) and returns count nil / `.motionObservedCountUnresolved` (:429-438) → "--" + "Strap motion found · count still resolving". And `receiptInvalidatesOlderPartial` (Atria/Atria/AtriaWhoop4MotionTickDailyStore.swift:462-470) lets that zero-step receipt override a *stronger* projected partial for the same wake window, so the day can go from a real number back to "--".

On the coverage fence specifically: the safe "separate lower-bound lane" from the 2026-08-08 investigation only half-shipped. What runs is `currentAndPriorStepReceiptWindows` (Atria/Atria/Sessions.swift:11445-11480) — current physiological cycle + the immediately prior one, exactly two windows. `completedPriorCivilDayWindows` (Atria/Atria/Sessions.swift:11482-11504) — the multi-day backfill the memory prescribed — has ZERO production callers; the only references are its own definition, two unit tests, and a source-scan pin at Atria/AtriaTests/AtriaWhoop4MotionTickDailyStoreTests.swift:1739-1741 that asserts it must NOT appear in the hot worker. So any day older than the immediately-prior cycle can only get steps from the joint canonical lane (`verifiedCanonicalStepEvidenceDaysCancellable`, Atria/Atria/Sessions.swift:19905-19951, fed into Home at Atria/Atria/AtriaHomeView.swift:10067 and 10875) — which on this device is parked (`terminalArchiveFailureDiagnostic.v1 = publicationCheckpointMissing`, 2026-08-14; `lastStatus = gap_retained_transaction_unverified`; `authority=gapResolvedConsumersPending`). That is why older days show no bars at all.

The 4 h stall is NOT the cause. It additionally starves tonight's receipt (the bank offload started 21:56:24, eight seconds before the link went silent, and `workoutMotion.backfillPending` is still true), but the presentation defects above are static code and reproduce on a fully-synced device.

**Evidence**

- Atria/Atria/AtriaDailyStepPresentation.swift:165-176 — valueText returns bare "\(count)" for a partial verified-canonical day; comment at :166-169 explicitly drops the "≥"/"~" qualifier
- Atria/Atria/AtriaDailyStepPresentation.swift:187-205 — partial detail line is "Counted through <time>"; the 2026-08-12 comment at :188-200 records the deliberate removal of the coverage percent from the glance line
- Atria/Atria/AtriaDailyStepPresentation.swift:257-264 — the only surviving coverage disclosure ("At least N steps, motion tracked for X percent of your day") is in accessibilityText, i.e. VoiceOver only
- Atria/AtriaTests/AtriaDailyStepPresentationTests.swift:113-137 — pinned expectation: 176 steps over 11,598 covered / 43,626 missing seconds renders as the string "176"
- Atria/AtriaWidget/AtriaWidget.swift:137-147 — atriaStepValueText returns "≥\(value)" when stepsSource == verifiedCanonical && stepsCompleteness == partial; the widget keeps the grammar the app drops
- Atria/Atria/AtriaHomeView.swift:3489-3512 — the same presentation is published to the widget snapshot with stepsCoverageFraction, which AtriaWidget.swift:314 stores and never renders
- Atria/Atria/AtriaStepsWeekChart.swift:25-31 — barTint grades each bar green/orange/red against the daily goal; :24 concedes "Bars are still verified LOWER BOUNDS"
- Atria/Atria/AtriaStepsWeekChart.swift:5-7 and :48-61 — documented contract "missing ≠ zero, never a zero-height bar", but a BarMark is drawn for any non-nil Int including 0, with a "0" annotation
- Atria/Atria/AtriaOverviewSections.swift:6479-6491 — loadWeekSteps maps receipt.steps with no completeness / zero / open-cycle filter, so an unresolved-motion receipt becomes a literal 0 bar and today's in-progress subtotal is charted as a completed day
- Atria/Atria/AtriaOverviewSections.swift:6404-6416 — the detail sheet renders ProgressView(count / goal) and "Saved progress N / 10000" for a partial lower bound (contrast stepsZone at :4766-4770, which correctly refuses to grade a partial canonical count)
- Atria/Atria/AtriaWhoop4MotionTickCompactStore.swift:2020-2048 — steps = estimate?.steps ?? 0; qualifiedSeconds = min(totalSeconds, knownSeconds) − unresolved; missingCoverageSeconds = totalWindowSeconds − qualifiedSeconds, so coverageFraction is measured against the whole wake window
- Atria/Atria/AtriaWhoop4MotionTickStepModel.swift:1854 — estimateCoveredActivityFragments returns nil when no run qualifies, driving steps=0 with motionTicks>0
- Atria/Atria/AtriaWhoop4MotionTickDailyStore.swift:735-744 — unresolvedObservedMotion (ticks>0 && steps==0) publishes knownCoverageSeconds = 0
- Atria/Atria/AtriaWhoop4MotionTickDailyStore.swift:462-470 — receiptInvalidatesOlderPartial lets a zero-step receipt replace a stronger projected partial for the same wake window
- Atria/Atria/AtriaDailyStepPresentation.swift:380-394 and :429-438 — partial lane requires knownCoverageSeconds > 0; otherwise hasUnresolvedMotionReceipt → .motionObservedCountUnresolved → count nil → "--"
- Atria/Atria/Sessions.swift:11445-11480 — currentAndPriorStepReceiptWindows: the ONLY receipt windows that run (current cycle + immediately prior)
- Atria/Atria/Sessions.swift:11482-11504 — completedPriorCivilDayWindows has no production caller anywhere in Atria/Atria (verified by repo-wide grep); the prescribed multi-day lower-bound backfill lane never shipped
- Atria/AtriaTests/AtriaWhoop4MotionTickDailyStoreTests.swift:1739-1741 — source-scan pin asserting the hot worker must NOT contain completedPriorCivilDayWindows(, confirming no other production lane was added
- Atria/Atria/Sessions.swift:19905-19951 and Atria/Atria/AtriaHomeView.swift:10067,10875 — older days reach Home only via verifiedHistoricalStepEvidenceDays from the joint canonical consumer sources, the lane the device shows parked (terminalArchiveFailureDiagnostic.v1 = publicationCheckpointMissing, 2026-08-14; offlineSync.lastStatus = gap_retained_transaction_unverified)
- Atria/Atria/AtriaWhoop4MotionTickStepModel.swift:237 — releaseDailyAuthorityQualified = true, so the step model qualification gate is NOT the blocker (rules out .stepModelNotQualified)
- Atria/Atria/Metrics.swift:298-307 — the "Partial · N% tracked" copy prior work believed covered steps belongs to the strain Confidence presentation, not to AtriaDailyStepPresentation

**Proposed fix**

Four bounded presentation fixes plus one wiring fix. None touch the joint proof, the coverage ledger, or the step model.

1. Restore lower-bound grammar in-app, matching the widget. Atria/Atria/AtriaDailyStepPresentation.swift:165-176 — when `source == .verifiedCanonical && completeness == .partial`, return "≥\(count)" (same rule as Atria/AtriaWidget/AtriaWidget.swift:142-145). Keep the `.live` partial as a plain number. Keep the :174 zero-suppression.

2. Put the coverage number back where the user can see it, without the failure connotation on the glance line. Atria/Atria/AtriaOverviewSections.swift:6404-6416 (Strap steps detail sheet, not the glance card): under the goal bar, render "Motion tracked for N% of this day" from `presentation.coverageFraction`, and gate the ProgressView so a partial lower bound draws in a neutral tint rather than the live/goal tint. Leave `detailText` (:187-205) alone — that decision was deliberate.

3. Stop grading lower bounds as pass/fail. Atria/Atria/AtriaStepsWeekChart.swift:25-31 — take completeness alongside the count (e.g. `stepsByDay: [Date: (steps: Int, isComplete: Bool)]`) and apply the green/amber/red goal verdict ONLY to complete days; partial days get one neutral tint plus a "≥" prefix on the per-bar annotation at :56-61. This mirrors the rule already honoured by `stepsZone` (Atria/Atria/AtriaOverviewSections.swift:4766-4770) and by the `valueStatusTint` doctrine in Atria/Atria/AtriaMetricConfidencePresentation.swift.

4. Never draw a fabricated zero, never chart the open cycle as a finished day. Atria/Atria/AtriaOverviewSections.swift:6484-6489 — skip receipts where `motionTicks > 0 && steps == 0` (unresolved motion is not a zero-step day; this is the same predicate as AtriaWhoop4MotionTickDailyStore.swift:735-736), and skip the receipt whose window is the still-open current cycle (`windowStart` equal to the active cycle start / `capturedThrough` within the live-evidence window) so today is not graded against a full-day goal.

5. Ship the lower-bound backfill lane that was designed but never wired. Add a production caller for `completedPriorCivilDayWindows` (Atria/Atria/Sessions.swift:11482) on the separately-admitted bounded background lane — the one already gated by `shouldAdmitBoundedLegacyCurrentCycleStepMigration` around Atria/Atria/Sessions.swift:11180-11200 — reading through `AtriaWhoop4MotionBankCoverageLedger.intervals` + `AtriaWhoop4MotionTickCompactStore.motionTickDayEvidenceRead` and saving via `AtriaWhoop4MotionTickDailyStore.shared.save`. Do NOT add it to the hot worker: the source pin at Atria/AtriaTests/AtriaWhoop4MotionTickDailyStoreTests.swift:1739-1741 must keep passing. This is what unblocks the days older than the immediately-prior cycle while the joint canonical publication stays parked.

**Test plan**

All pure, in the existing suites (scheme AtriaTests), no device and no multi-save integration store.

1. Atria/AtriaTests/AtriaDailyStepPresentationTests.swift — extend `testTerminalPureHRMotionRetainsLowerBoundAndShowsBlocker` (:129) / `partialVerified176()` (:113): assert `value.valueText == "≥176"` for the verified-canonical partial, and assert a `.live` partial still renders bare. Add a regression asserting app `valueText` and the widget's `atriaStepValueText` agree for the same (source, completeness) pair, so the two can never diverge again.

2. New `AtriaStepsWeekChartInputTests` (or extend Atria/AtriaTests/AtriaWhoop4MotionTickDailyStoreTests.swift:229-242, which already reproduces `loadWeekSteps` inline): save a receipt with `ticks: 200, steps: 0` and assert the derived map has NO entry for that day (today's regression: it yields 0 and draws a "0" bar). Save a receipt whose window is the open current cycle and assert it is excluded from the completed-day map. Save a complete day and assert it survives.

3. `AtriaStepsWeekChart` tint test: assert `barTint` returns the neutral tint for a partial day at 4% of goal and the red tint only for a complete day at 4% of goal — the "never grade a lower bound" rule.

4. Backfill-lane reachability pin (repo already uses source-scan pins, cf. Atria/AtriaTests/AtriaHistoryProjectionBoundaryTests.swift:41): assert `Sessions.swift` contains a production call site for `completedPriorCivilDayWindows(` outside `startCurrentCycleStrapStepReceiptRead`, while the existing negative pin at AtriaWhoop4MotionTickDailyStoreTests.swift:1739-1741 (must be absent from the hot worker body) still holds. Plus a pure test on `completedPriorCivilDayWindows` monotonicity/precedence: a backfilled prior-day receipt must never override an exact canonical total and must never decrease on refresh.

**Noticed nearby**

- Fabricated zero: an unresolved-motion receipt (firmware ticks > 0, qualified gait 0) becomes `map[day] = 0` in Atria/Atria/AtriaOverviewSections.swift:6488 and Swift Charts draws a bar annotated "0", violating the chart's own written contract at Atria/Atria/AtriaStepsWeekChart.swift:5-7. `AtriaDailyStepPresentation.valueText:174` guards against exactly this for the card but nothing guards the chart.
- App/widget disagreement on the same snapshot: widget "≥176" (AtriaWidget.swift:142-145) vs card "176" (AtriaDailyStepPresentation.swift:165-176). `stepsCoverageFraction` is faithfully published into the widget snapshot (AtriaHomeView.swift:3509, WidgetSnapshot.swift:521) and then never rendered anywhere (AtriaWidget.swift:314 stores it, no reader).
- Sticky "--": `receiptInvalidatesOlderPartial` (AtriaWhoop4MotionTickDailyStore.swift:462-470) lets a zero-step receipt beat a stronger projected partial for the same wake window, so a day that showed a real number can revert to "--" with "Strap motion found · count still resolving".
- Dead code with tests: `completedPriorCivilDayWindows` (Sessions.swift:11482) is fully implemented and unit-tested (AtriaWhoop4MotionTickDailyStoreTests.swift:198-222) but has no production caller — the Aug-8 "safe fix" landed as a helper only.
- Adjacent to item 12: the step lane's own durable store is bounded to 32 records / 512 KB (AtriaWhoop4MotionTickDailyStore.swift:56-57) — insight-tier data is already cheap; the 5.45 GB is entirely the raw/identity tier, so "insights forever, raw for a week" is structurally easy here.
- Adjacent to item 4: steps are attributed wake-to-wake off `AtriaPhysiologicalCycle.current` (Sessions.swift:130-166). When no main sleep is confirmed, the no-sleep fallback rolls the boundary and today's step count legitimately resets to "--" with a "Yesterday: ≥N" disclosure (AtriaDailyStepPresentation.swift:213-227). Given items 5/6 (sleeps left unsaved, naps never detected), this rollover will fire more often than intended and is a second, independent source of "steps vanished".

**Challenger 1 — refuted=False**

I verified every cited file:line against the real source on codex/whoop-remaining-product-gaps (HEAD 47538c32). The mechanism is confirmed by code reading, not accepted on assertion.

MECHANISM 1 — CONFIRMED, and stronger than claimed.
AtriaDailyStepPresentation.swift:165-176 returns bare "\(count)" for partial; the comment at :166-169 explicitly names the dropped "≥"/"~". detailText:187-205 is "Counted through <time>" with the 2026-08-12 comment recording deliberate removal of the percent. accessibilityText:257-264 is the sole surviving coverage disclosure. Test pins confirmed at AtriaDailyStepPresentationTests.swift:131 and :137 (valueText == "176"). Widget confirmed: AtriaWidget.swift:142-145 returns "≥\(value)".
I also traced every in-app consumer: Home glance (AtriaHomeView.swift:9267 strapStepResearchText), Strap steps sheet (AtriaOverviewSections.swift:6385), History row (Sessions.swift:55544) — all render presentation.valueText, so "every in-app surface" is literally true.
A repo-wide grep for "≥" in the app target shows the lower-bound grammar IS shipped, but only for strain (AtriaWorkoutMetricPresentation.swift:262, Metrics.swift:301, AtriaMetricConfidencePresentation.swift:125), workout calories (:306), and HR zones — never for daily steps. isLowerBound:true is produced ONLY by AtriaCompactMetricPresentation.strain (:313), which independently confirms the claim's last evidence item (Metrics.swift:298-307 belongs to strain, not steps).
Strongest point the claim understates: AtriaDailyStepPresentation ALREADY uses "≥" for the prior-cycle lower bound at :221 and :223. So the file's own grammar for a step lower bound is "≥", applied everywhere except today's partial. This is an internal inconsistency, not merely app-vs-widget.

MECHANISM 2 — CONFIRMED with one code-level correction.
AtriaStepsWeekChart.swift:25-31 barTint grades red/amber/green against goal; :24 concedes "Bars are still verified LOWER BOUNDS"; contract at :5-7 confirmed; BarMark at :48-61 draws for any non-nil Int including 0 with a "0" annotation. AtriaOverviewSections.swift:6407/6414 renders "Saved progress N / goal" + ProgressView(count/goal) for a partial lower bound, while stepsZone at 4766-4770 correctly refuses to grade one (guard completeness != .partial || source == .live). The contrast is real.

MECHANISM 3 — CONFIRMED end to end.
AtriaWhoop4MotionTickStepModel.swift:1854 `guard !estimates.isEmpty else { return nil }`; CompactStore:2020-2048 `steps: estimate?.steps ?? 0` w

_Corrections:_ Three corrections. None overturn the root cause; two narrow it and one reassigns a surface.

1. loadWeekSteps is not an unfiltered assign. AtriaOverviewSections.swift:6479-6491 actually reads `map[day] = max(map[day] ?? 0, receipt.steps)`, not `map[day] = receipt.steps`. A zero-step unresolved receipt therefore CANNOT clobber a stronger receipt for the same civil day. The fabricated-zero bar is real but narrower than claimed: it occurs only when the day's sole receipt is the unresolved-motion one. Fix 4 is still correct — the max-merge does not stop a lone zero from charting as "0" — but the rationale should say "a day whose only receipt is unresolved" rather than "no filter".

2. The detail sheet does not colour-grade the partial. AtriaOverviewSections.swift:6414 tints the ProgressView with `status.tint`, which is motion-liveness, not a goal verdict. The sheet's defect is that it renders a lower bound as a fraction of a whole-day goal ("Saved progress 176 / 10000"), implying completeness — it does not paint it red. Only AtriaStepsWeekChart applies the red/amber/green pass-fail grade. Fix 2's "gate the ProgressView so a partial draws in a neutral tint" is still worth doing, but the pass/fail grading complaint belongs solely to fix 3.

3. Wrong producer wired to the week chart. The claim's line "That is why older days show no bars at all" attributes empty older-day bars to the parked joint canonical lane. That is incorrect. AtriaStepsWeekChart is fed by loadWeekSteps → AtriaWhoop4MotionTickDailyStore.shared.recentReceipts(limit: 14), a DURABLE store retaining up to 32 records (maximumRecords = 32 at AtriaWhoop4MotionTickDailyStore.swift:57). Those receipts accumulate: each day's receipt is written while that day is the current or immediately-prior cycle and persists afterwards. So older days do get week-chart bars whenever the app refreshed on those days. What the parked canonical lane actually empties is the History "Daily steps" section (Sessions.swift:52779-52787,

**Challenger 2 — refuted=False**

I re-derived the chain from the compact-store projection through the daily-store receipt, the presentation resolver, and every in-app surface, and I reach the same primary mechanism the other investigator did. Verified independently:

ENGINE (agrees). Steps only ever exist for the fraction of the cycle where the 0x69 motion bank was armed/offloaded AND the gravity-cadence model qualified a run. `AtriaWhoop4MotionTickCompactStore.swift:2032-2050` computes `qualifiedSeconds = min(totalSeconds, knownSeconds) - unresolvedMotionSeconds` and `steps: estimate?.steps ?? 0` (:2043), so `coverageFraction` is qualified-seconds ÷ whole-cycle-seconds and the count is a strict lower bound. `AtriaHistoricalStepRecovery.swift:3-9` confirms downloaded 1 Hz gravity rows are never step evidence, so there is no second lane that could fill the gap. Nothing scales, extrapolates, or suppresses — the engine is honest.

MECHANISM 1 (confirmed, and it is the dominant one). `AtriaDailyStepPresentation.valueText` returns a bare `"\(count)"` for `(.verifiedCanonical, .partial)` (AtriaDailyStepPresentation.swift:165-176), and `detailText` for that case returns "Counted through <time>" (:187-205) with the coverage percent deliberately deleted on 2026-08-12. The percent survives only in `accessibilityText` (:257-264) — VoiceOver only. The widget renders the same snapshot as "≥176" (AtriaWidget.swift:137-146, prefix at :144). App and widget contradict each other; the app is the dishonest one. The pinned test proves the shape and even forbids the honesty token: `XCTAssertFalse(value.detailText.contains("%"))` (AtriaDailyStepPresentationTests.swift:103-104).

MECHANISM 2 (confirmed). `AtriaStepsWeekChart.barTint` (:25-31) reds any bar under 50% of goal while its own doc at :22-24 concedes the bars are lower bounds and claims "every bar is a COMPLETED day"; `loadWeekSteps` (AtriaOverviewSections.swift:6479-6491) feeds it `recentReceipts(limit: 14)` including the still-open current-cycle receipt, and line 6488 (`map[day] = max(map[day] ?? 0, receipt.steps)`) admits a zero, which Swift Charts draws as a zero-height bar annotated "0" — violating the chart's own contract at :5-7.

DEAD LOWER-BOUND LANE (confirmed). `completedPriorCivilDayWindows` (Sessions.swift:11482-11504) has zero production callers; the only live lane is `currentAndPriorStepReceiptWindows` (:11445-11480), used once at :11558, and a source-scan pin at AtriaWhoop4MotionTickDailyStoreTests.swift:1739-1741 asserts the civil-day 

_Corrections:_ Their mechanisms (1) and (2) and the dead-lane finding are correct and independently reproduced. Two corrections and two additions.

CORRECTION A — mechanism (3)'s chain is broken at a validation gate they did not check.
They claim: `estimateCoveredActivityFragments` returns nil (AtriaWhoop4MotionTickStepModel.swift:1854) → compact publishes `steps: 0` with `qualifiedSeconds` 0 → `stepDay` sets `unresolvedObservedMotion` and zeroes coverage (AtriaWhoop4MotionTickDailyStore.swift:735-744) → resolve returns `.motionObservedCountUnresolved` → "--".
That cannot happen. A receipt with `knownCoverageSeconds <= 0` is rejected before persistence: `validationFailure` returns "missing_known_coverage" (AtriaWhoop4MotionTickDailyStore.swift:647-649), `save` throws (:209-227), and the worker only logs `receipt_save_failed` (Sessions.swift:11680-11692). And `stepDay` is invoked from exactly one site — :434, inside `currentCyclePublication`, on a record already read back from the persisted store (:414-421). So the zero-coverage receipt never reaches `stepDay`.
`.motionObservedCountUnresolved` IS still reachable, but only from a persisted receipt with `knownCoverageSeconds > 0` AND `motionTicks > 0` AND `steps == 0` (all runs qualified as non-gait). Narrower than claimed.

CORRECTION B — `receiptInvalidatesOlderPartial` cannot demote the store's own stronger number.
They say a zero-step receipt "lets the day go from a real number back to '--'". `saveValidated` (AtriaWhoop4MotionTickDailyStore.swift:246-278) explicitly rebuilds weaker incoming evidence from the strongest stored record's `motionTicks`/`steps`/`knownCoverageSeconds`, only advancing `capturedThrough`. So the durable receipt's number is protected. `receiptInvalidatesOlderPartial` (:462-470) can only override a stronger row from the *canonical archive* projection — which on this device is frozen since 2026-08-14, making that path largely moot here.
The "--" they observed is real but arrives by a simpler route: no admissi


---

### Item 10 — real-defect (refuted 0/2, confidence high)

**Root cause**

Two gates in `AtriaSleepWakeResearch.stageSegmentsCore` make stages unreachable on this device, and neither is the 4 h stall.

GATE A (why the card is blank every morning, before any backfill). `AtriaSleepWakeResearch.swift:295` — `guard motionBacked || allowHROnlyEstimate else { return [] }`. `allowHROnlyEstimate` defaults to `false`, and BOTH automatic persistence builders omit it: `Sessions.swift:37224` (`preparedAutoSleepMaterialization`) and `Sessions.swift:37500` (`buildAutoConfirmedSleep`), as do the daily-metric and review projections (`Sessions.swift:20156, 34443, 34459, 34878, 34890, 43918`). `motionBacked` comes from `AtriaRecoveredMotionAnalytics.sleepProvenance` which requires `validatedFraction >= 0.80 && maximumGap <= 90` (`AtriaRecoveredMotionAnalytics.swift:189-193`); with `workoutMotion.backfillPending=true` and the chronic imu backlog there are zero recovered epochs, so `hasRecoveredEpochs=false` → `measurementSufficient=false`. The night is therefore persisted with `stageSegments = []` → `Night.stageEvidence = .none` (`Sessions.swift:54014-54016`, `hasSegments == false`) → `displayState` falls through to `.building` (`AtriaSleepHypnogram.swift:382`) → the user sees "Stage analysis unavailable for this night / Your sleep duration is saved. Hours asleep alone do not create a hypnogram." plus the unlock promise "Stages validate after the strap syncs motion for this night — motion sync is catching up now." (`AtriaSleepHypnogram.swift:463-467`, `:483-490`).

GATE B (the real blocker — why the promise in that copy can never be kept, and why the HR-only estimate lane never fires either). The only lane that opts in on every launch is `backfillConfirmedSleepStagesFromSessions` (`Sessions.swift:41605`, called with reason `deferred_session_load` at `Sessions.swift:51294`, `allowHROnlyEstimate: true` at `:41752`). It gets past Gate A and then dies at `AtriaSleepWakeResearch.swift:321-326` → `heartRateEvidenceIsDense` (`:593-623`). That function rejects the ENTIRE night if ANY consecutive HR sample pair is more than `maximumHeartRateGap = 15` seconds apart (`:137`, loop at `:613-620`), or if the first sample is >15 s after window start / last sample >15 s before window end (`:609-610`). It runs unconditionally AFTER the motion gate, so it blocks the motion-validated lane identically — motion arriving cannot unlock stages.

That 15 s bar is unachievable on this stack, and every other layer contradicts it:
- The sleep window's own bounds are session bounds, not sample bounds: `start = cluster.first?.start`, `end = cluster.last?.end` (`Sessions.swift:44882`), so the `:609-610` edge checks fail on ordinary journal lead-in/lead-out.
- The credited sleep duration EXPLICITLY includes unmeasured time: `totalDuration = capturedDuration + briefGapCredit` where each inter-session gap up to `briefSleepGapCreditMax = 20*60` is credited as sleep (`Sessions.swift:5075`, `:44836-44846`). Any night that used one second of that credit is permanently unstageable.
- Admission tolerates 600 s HR holes (`maximumHRSampleGap <= 10 * 60`, `Sessions.swift:45065`) and 60 s accepted-HR holes (`maximumAcceptedHRGap <= 60`, `:45066`) at its STRICTEST tier — 4× to 40× looser than the stager.
- The BLE layer manufactures >15 s holes by design: it does not even call the stream stalled until `hrContinuityWatchdogTimeout = max(20, min(acceptedHRTimeout*2/3, 45))` ≈ 30 s (`AtriaBLEManager.swift:7371-7374`), hard-reconnects are rate-limited to one per 120 s (`:19109-19113`), and any ≥90 s silence splits the journal into a new session (`activeJournalSegmentGapLimit = 90`, `AtriaBLEManager.swift:5013`, used at `:41463`). The device shows `keepalive.stallReconnects = 323` and `lastDisconnectCause = hr_continuity_background_all_gatt_silent_rebuild` — every one of those recovery cycles leaves a hole that exceeds 15 s.
- The repo's own physical finding says a HEALTHY long-wear link delivers "ordinary 8–14 second HR intervals" (`AtriaBLEManager.swift:7366`). That is 1 second of margin against the 15 s hard limit, and at 8–14 s spacing the night also fails the separate `minimumHeartRateSamplesPerMinute = 6.0` count bar (`:138`, checked at `:605-608`), which needs ≤10 s average spacing.

The gate is also redundant with a correct gate that already exists. `epochFeatures` refuses to classify any 30 s epoch that has no local HR sample (`AtriaSleepWakeResearch.swift:439-442`, `guard !epochRange.isEmpty else { continue }`), so unsupported time is dropped rather than fabricated, and the OUTPUT timeline is then re-checked for ≥85% coverage and ≤90 s maximum hole by `timelineHasDenseLocalEvidence` (`:355-358`, `:564-591`, constants `minimumTimelineCoverageFraction = 0.85` / `maximumEvidenceGap = 90` at `:135-136`). The input gate enforces the same safety property at 6× the strictness with whole-night all-or-nothing semantics. Its own comment claims the constants "match the recovered-motion receipt's maximum tolerated hole" (`:131-134`) — the motion receipt tolerates 90 s; the HR input gate tolerates 15 s.

The 15 s constant landed 2026-08-11 in ab071eb3 and has never been revised — i.e. it has been in force for the entire 3-4 day field window. Note also the stage engine consults zero RR/HRV (no RR reference exists anywhere in `AtriaSleepWakeResearch.swift`), so the 0.60 RR-coverage bars in the brief belong to the DETECTION tiers only (`Sessions.swift:45062-45063`) and are not what blocks stages. Detection is passing — a 303-minute sleep was confirmed and a morning summary fired for 2026-08-18 — which is precisely why this is not starvation: the evidence to stage existed and was rejected.

**Evidence**

- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:137 — `private static let maximumHeartRateGap: TimeInterval = 15` (the blocking constant)
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:613-620 — whole-night loop: `if samples[index].t.timeIntervalSince(samples[index - 1].t) > maximumHeartRateGap { return false }` — one gap kills the entire night
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:609-610 — window-edge checks `first.t - start <= 15` and `end - last.t <= 15`, against session-derived bounds
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:321-326 — `guard try heartRateEvidenceIsDense(...) else { return [] }`, unconditional, applies to the motion-validated lane too
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:295 — `guard motionBacked || allowHROnlyEstimate else { return [] }`
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:138 + :605-608 — `minimumHeartRateSamplesPerMinute = 6.0` requires <=10 s average spacing across the whole window
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:439-442 — `guard !epochRange.isEmpty else { continue }`: unsupported epochs are already dropped, never fabricated
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:355-358 + :564-591 + :135-136 — output gate already enforces >=0.85 coverage and <=90 s hole (`timelineHasDenseLocalEvidence`)
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepWakeResearch.swift:131-134 — comment claims these constants 'match the recovered-motion receipt's maximum tolerated hole' (which is 90 s, not 15 s)
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:37224 and :37500 — both automatic confirmed-sleep builders call `sleepStageResearchSegments` without `allowHROnlyEstimate` (defaults false)
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:41752 + :51294 — the only always-on opt-in lane (`backfillConfirmedSleepStagesFromSessions`, reason `deferred_session_load`)
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:44882 — `start = cluster.first?.start, end = cluster.last?.end` (window bounds are session bounds, not sample bounds)
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:5075 + :44836-44846 — `briefSleepGapCreditMax = 20*60`; `totalDuration = capturedDuration + briefGapCredit` credits unmeasured gaps as sleep
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:45065-45066 — strictest admission tier still allows `maximumHRSampleGap <= 10*60` and `maximumAcceptedHRGap <= 60`
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:45062-45063 — the 0.60 HR/RR coverage bars are DETECTION-tier only; `hrSampleCoverageFraction = allHR.count / totalDuration` (Sessions.swift:44981) so 0.60 = 36 samples/min, far above the stager's 6/min
- /Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:54013-54024 — `stageEvidence(source:confirmed:hasSegments:)` returns `.none` when segments are empty; `qualifiesForHROnlyEstimate` also requires `!stageSegments.isEmpty`
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepHypnogram.swift:382 — `guard !segments.isEmpty ... else { return .building }`
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepHypnogram.swift:463-467 — the `.building` honest state the user is actually seeing
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaSleepHypnogram.swift:483-490 — `unavailableStagesDetail` promises 'Stages validate after the strap syncs motion for this night', a promise Gate B can permanently block
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaRecoveredMotionAnalytics.swift:189-193 — `sufficient = duration >= 20*60 && validatedFraction >= 0.80 && maximumGap <= 90 && ...` (zero epochs => false)
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaBLEManager.swift:7366 — 'ordinary 8–14 second HR intervals' documented as HEALTHY long-wear behavior
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaBLEManager.swift:7371-7374 — `hrContinuityWatchdogTimeout = max(20, min(acceptedHRTimeout * (2.0/3.0), 45))`: the link is not considered stalled until ~30 s of silence
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaBLEManager.swift:5013 + :41463 — `activeJournalSegmentGapLimit = 90`: any >=90 s silence splits the journal into a new session
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaBLEManager.swift:19109-19113 — hard-reconnect cooldown of 120 s between stall recoveries
- /Users/amanpandey/projects/atria/Atria/Atria/AtriaBLEManager.swift:4970-4975 — `longWearLiveSessionRetentionSpan = 3*60*60`: a 5 h sleep always spans multiple sessions
- git ab071eb3 (2026-08-11) — sole commit touching `maximumHeartRateGap`; in force for the whole field window
- Device: keepalive.stallReconnects=323, lastDisconnectCause=hr_continuity_background_all_gatt_silent_rebuild, workoutMotion.backfillPending=true
- Device: notification.sleepEvent.lastDay=2026-08-18 lastKind=morning_summary lastDurationMinutes=303 — detection succeeded and credited 5 h 03 m, so stage evidence existed and was rejected

**Proposed fix**

Three changes, ordered by impact.

1. (PRIMARY) Replace the binary whole-night HR input gate with a coverage gate symmetric to the output gate.
   - `Atria/Atria/AtriaSleepWakeResearch.swift:137` — change `maximumHeartRateGap` from `15` to `90` so it actually matches `maximumEvidenceGap` (`:135`) as its own comment at `:131-134` claims. This simultaneously fixes the per-pair loop (`:613-620`) and the window-edge checks (`:609-610`), and aligns the stager with the 90 s bar used everywhere else in the stack (`activeJournalSegmentGapLimit`, `AtriaRecoveredMotionAnalytics` sufficiency, `AtriaSleepStageIntegrity.validates`).
   - `Atria/Atria/AtriaSleepWakeResearch.swift:605-608` — compute `requiredSamples` over HR-SUPPORTED time rather than the full `duration`, or drop `minimumHeartRateSamplesPerMinute` (`:138`) entirely. As written it penalizes a night for holes a second time, and at the documented healthy 8–14 s long-wear cadence (`AtriaBLEManager.swift:7366`) it fails a flawless night outright.
   This is safe without further work: `epochFeatures` already refuses to classify an epoch with no local HR sample (`:439-442`), and the merged timeline is re-checked at `:355-358` against >=85% coverage / <=90 s hole. Unsupported time is dropped, never painted.

2. (VISIBILITY) Make automatic settlement stop storing a silently stage-less night. Either pass `allowHROnlyEstimate: true` at `Atria/Atria/Sessions.swift:37224` and `:37500`, or accept the deferred launch backfill but stop the card from promising an unlock it cannot deliver. Today the cost argument for the opt-in (`AtriaSleepWakeResearch.swift:288-294`) is sound, so prefer leaving these `false` AND doing item 3 — but if the estimate is cheap enough post-fix-1, flipping `:37500` (the non-deadline path) gives same-morning stages.

3. (HONESTY) Emit a stage-withheld reason. `stageSegmentsCore` returns `[]` from four distinct places (`:295`, `:326`, `:351`, `:355`) with no reason code, and production has no diagnostic at all — `fallbackStageDiagnostics` (`:525`) has zero non-test callers. Return a typed withheld-reason (`insufficientMotion`, `hrGap(seconds:)`, `epochQuorum`, `timelineCoverage`), persist it on the night, and have `AtriaSleepHypnogram.unavailableStagesDetail` (`AtriaSleepHypnogram.swift:483-490`) render the true blocker instead of "Stages validate after the strap syncs motion for this night", which the HR gate can make permanently false. This is required by the fail-closed-states-must-be-visible rule; right now the app cannot tell the user, or us, why it withheld.

Do NOT change `AtriaSleepStageIntegrity.validates` / `reconcilesForPresentation` (`Sessions.swift:3685-3810`) or the `.hrOnlyEstimate` labeling path — those are correct and are not what is blocking.

**Test plan**

Add `Atria/AtriaTests/AtriaSleepStageHRGapTests.swift` (scheme AtriaTests). Existing coverage is the hole: every fixture in `AtriaSleepStageFallbackPerformanceTests.swift` is gapless — 1 Hz at `:66-70`, 5 s stride at `:104-109` — and `:230-257` only ever gaps the MOTION epochs, never HR. No test anywhere feeds the stager an HR seam.

1. `testRealisticReconnectSeamStillStages` — build a 6 h 1 Hz `[AtriaSleepWakeResearch.HeartSample]` night at bpm ~58, delete a 120 s block at t+3h (the exact shape `activeJournalSegmentGapLimit = 90` produces), call `AtriaSleepWakeResearch.stageSegments(samples:start:end:restingHR:isNap:false,motionValidated:false,motionEpochs:[],allowHROnlyEstimate:true)`; assert `!stages.isEmpty` and that every returned id carries `SleepStageSegment.hrEstimateIDPrefix`. Pre-fix this fails (empty).
2. `testStagedTimelineStillPassesIntegrity` — same fixture; assert `AtriaSleepStageIntegrity.validates(stages, start:end:duration:span:)` holds with `duration` = HR-covered time, proving the relaxed input gate does not let an unsupported timeline through.
3. `testSparseNightStillFailsClosed` — same 6 h window with a single 30 min hole (coverage <0.85); assert `stages.isEmpty`. This pins that `timelineHasDenseLocalEvidence` is the real safety property and that fix 1 did not remove fail-closed behavior.
4. `testStagerToleranceIsAtLeastAdmissionTolerance` — contract test over the two constants: assert `AtriaSleepWakeResearch` max tolerated HR hole >= `AggregateSleepCandidate` strictest admitted hole, so a night the app credits as sleep can always be staged. Encode it as a fixture at `maximumAcceptedHRGap = 60` (Sessions.swift:45066) and assert non-empty stages.
5. `testWithheldReasonIsReported` (for fix 3) — assert an HR-only night with insufficient motion and a 30 min hole reports `timelineCoverage`, not `insufficientMotion`, so the card cannot promise a motion unlock that would not help.

Run: `xcodebuild test -scheme AtriaTests -only-testing:AtriaTests/AtriaSleepStageHRGapTests`. Then re-run `AtriaSleepEstimateReconcileTests`, `AtriaSleepStageIntegrityTests`, `AtriaSleepStageFallbackPerformanceTests`, `AtriaRecoveredMotionAnalyticsTests` for regressions (note the known pre-existing `AtriaSleepStageIntegrityTests` source-scan drift and `testReclassifyToNap` flake — baseline them before judging).

**Noticed nearby**

1. The user-facing copy is actively misleading, not merely empty. `AtriaSleepHypnogram.swift:483-490` tells the user "Stages validate after the strap syncs motion for this night — motion sync is catching up now." Gate B runs after the motion gate (`AtriaSleepWakeResearch.swift:321`), so a completed motion offload changes nothing for any night with a >15 s HR hole. The app is promising an unlock the code cannot deliver — a direct violation of the honesty rule, and it is why this has stayed invisible: the user waits for a sync that would not have helped.

2. There is no production diagnostic for stage withholding at all. `stageSegmentsCore` has four silent `return []` exits and `fallbackStageDiagnostics` (`AtriaSleepWakeResearch.swift:525`) has zero non-test callers. `backfillConfirmedSleepStagesFromSessions` only logs on success (`Sessions.swift:41781`, `:41848`). Nothing on the device dump could ever have told us which gate fired — that absence is itself a defect and is why item 10 needed a code read rather than an evidence read.

3. Internal constant contradiction worth a separate cleanup: the comment at `AtriaSleepWakeResearch.swift:131-134` asserts these constants "match the recovered-motion receipt's maximum tolerated hole", but the motion receipt tolerates 90 s (`AtriaRecoveredMotionAnalytics.swift:191`) and the HR input gate tolerates 15 s. The stated intent and the code disagree by 6×, which suggests the 15 was a typo or an unreviewed tightening in ab071eb3 rather than a deliberate calibration.

4. Adjacent to item 5 (the repeating sleep recommendation): `shouldRefreshUserAdjustedSleepEvidence` (`Sessions.swift:41442-41462`) hard-gates on `source.hasPrefix("user_adjusted_")`, so the evidence-refresh lane never revisits an auto-confirmed night. Combined with the stage-less store this means an auto-confirmed HR-only night is effectively frozen. Worth checking against item 5's owner.

5. `hrv.lastReadyAnalysisAt` being 8 days stale (2026-08-11) is NOT this mechanism — it is written from `snapshot.isReady` on the RR/tachogram path (`AtriaBLEManager.swift:24525-24531`, `HRV.swift:124`) and the stage engine consults zero RR. The date coinciding with ab071eb3 (2026-08-11) is worth a look by whoever owns items 8/9, but I found no code coupling between the two.

6. Not stage-related but noticed while tracing storage: `coldSessionAgeDays = 30` / `residentSessionHistoryDays = 92` (`Sessions.swift:26308`, `:26313`) retain full-fidelity session points indefinitely with no prune, which is part of item 12's 5 GB. Good news for stages though — a retro re-stage after the fix will find intact 1 Hz points for every night in the window.

**Challenger 1 — refuted=False**

NOT REFUTED. I read every cited file:line on branch codex/whoop-remaining-product-gaps (HEAD 47538c32) and the mechanism is real, correctly located, and correctly ordered.

CONFIRMED VERBATIM:
1. AtriaSleepWakeResearch.swift:135-138 — `maximumEvidenceGap = 90`, `minimumTimelineCoverageFraction = 0.85`, `maximumHeartRateGap = 15`, `minimumHeartRateSamplesPerMinute = 6.0`, all four under the :131-134 comment asserting they "match the recovered-motion receipt's maximum tolerated hole". The 15 s constant sits two lines below the 90 s constant it claims to match. The internal contradiction the claim alleges is literally on the page.
2. `heartRateEvidenceIsDense` (:592-622) is exactly as described: `requiredSamples = ceil(duration/60 * 6.0)` with `samples.count >= requiredSamples`; `first.t - start <= 15`; `end - last.t <= 15`; then a whole-night loop returning false on ANY consecutive pair > 15 s. Binary, all-or-nothing.
3. Call order verified: `guard motionBacked || allowHROnlyEstimate else { return [] }` at :295, then the HR density guard at :321-326. The HR gate is unconditional and DOES apply to the motion-validated lane. Motion arriving cannot unlock stages. The in-code comment at :288-294 even states this ("Every other gate below ... applies identically to both lanes").
4. `motionBacked` = `AtriaRecoveredMotionAnalytics.sleepProvenance(...).measurementSufficient`; :186-192 requires `validatedFraction >= 0.80 && maximumGap <= 90 && !intensities.isEmpty && !stillnesses.isEmpty`. Zero recovered epochs => `intensities.isEmpty` => false. Gate A closes as described.
5. Gate A callers: Sessions.swift:37224 (`preparedAutoSleepMaterialization`) and :37500 (`buildAutoConfirmedSleep`) both omit `allowHROnlyEstimate` (default false at AtriaSleepWakeResearch.swift:234 and Sessions.swift:39903/39923). Only `backfillConfirmedSleepStagesFromSessions` passes `allowHROnlyEstimate: true` (:41752), invoked once per launch at :51294 with reason `deferred_session_load`. Confirmed.
6. Sample provenance verified — the decisive check the claim did not spell out. `sleepStageResearchSegmentsCore` (Sessions.swift:39941-40006) builds `samples` from `session.points` only. That is the live accepted-BLE HR stream, i.e. the exact stream AtriaBLEManager.swift:7363-7366 documents as healthy at "ordinary 8-14 second HR intervals", and which AtriaBLEManager.swift:5008-5013 independently documents as legitimately exceeding 30 s at low-battery cadence. There is no interpolation, densification 

_Corrections:_ The root cause and both gates are correct as written. Three corrections — two to the evidence, one substantive gap in the fix.

CORRECTION 1 (evidence, and it makes the claim STRONGER). The claim calls `maximumHRSampleGap <= 10*60` / `maximumAcceptedHRGap <= 60` (Sessions.swift:45065-45066) "the STRICTEST admission tier". It is not. Those lines belong to `denseLongHROnlyReviewReady`, one of two HR-only *review* tiers. A 303-minute night is admitted by `strictDurationReady` (Sessions.swift:44945), which is `totalDuration >= strictMinimumDuration` (3 h, :5039) and imposes NO HR density or gap bar whatsoever. The only density bar an auto-confirmed night must clear is `hrObservedCoverageFraction >= minimumAutoConfirmHRCoverageFraction` (0.80), applied at Sessions.swift:38390, :38455, :38483 — and that fraction is computed over FIVE-MINUTE bins (`binSeconds: TimeInterval = 5 * 60`, Sessions.swift:44897-44928): a bin counts as observed if it holds a single sample. So the system will credit and announce a 5 h sleep on evidence as thin as one HR sample per 5 minutes across 80% of bins, then refuse to stage it unless every consecutive pair is within 15 s. The real asymmetry is ~20x worse than the claim states.

CORRECTION 2 (evidence). The claim's sub-argument that the night "also fails `minimumHeartRateSamplesPerMinute = 6.0`" is asserted, not established, for this specific night — nothing in the admission path measures per-minute density, so the actual cadence is unknown from code alone. It is also a red herring for the opposite case: had the night come through a dense review tier (`hrSampleCoverageFraction >= 0.60` = 0.6 samples/second = 36/min, Sessions.swift:44981, :45062), the 6/min count bar would pass trivially — yet those same tiers explicitly permit `maximumAcceptedHRGap <= 90` (:45048) and `<= 60` (:45066), so the 15 s pair loop still kills them. Either way the max-gap bar (:613-620), not the count bar, is the certain blocker. The count bar should still be fixed (

**Challenger 2 — refuted=False**

CONFIRMED, independently re-derived. I read the engine before reading their argument's citations and arrived at the same terminal gate.

WHAT THE USER SEES. Verified end-to-end: empty `stageSegments` → `SleepHistorySnapshot.Night.stageEvidence(source:confirmed:hasSegments:)` at Sessions.swift:54015-54016 `guard hasSegments else { return .none }` → `AtriaSleepHypnogram.displayState` Atria/Atria/AtriaSleepHypnogram.swift:399 `guard !segments.isEmpty ... else { return .building }` → the `.building` branch at :463-467 renders "Stage analysis unavailable for this night / Your sleep duration is saved. Hours asleep alone do not create a hypnogram." plus `unavailableStagesDetail` (:483-495) appending "Stages validate after the strap syncs motion for this night — motion sync is catching up now." So: a fail-closed message with a promise that cannot be kept, not a blank and not an estimate.

STARVED OR BROKEN — decisively BROKEN. The motion gate at Atria/Atria/AtriaSleepWakeResearch.swift:295 (`guard motionBacked || allowHROnlyEstimate else { return [] }`) is bypassed on the launch lane, and the HR density gate at :321-326 runs AFTER it and unconditionally on BOTH lanes. Motion arriving cannot unlock stages. The uncapped, opt-in lane that runs every launch is `backfillConfirmedSleepStagesFromSessions` (Sessions.swift:41604), invoked with reason `deferred_session_load` at Sessions.swift:51294, calling the stager at :41739 with `allowHROnlyEstimate: true` (:41752) and `maximumRows: Int.max`. Its only remaining blocker is the density gate.

THE BLOCKING GATE. `AtriaSleepWakeResearch.heartRateEvidenceIsDense`, Atria/Atria/AtriaSleepWakeResearch.swift:593-623, constants at :137-138 (`maximumHeartRateGap = 15`, `minimumHeartRateSamplesPerMinute = 6.0`). Three whole-night all-or-nothing conditions: ≥6 samples/min over the full window (:605-608), first/last sample within 15 s of the window edges (:609-610), and EVERY consecutive sample pair ≤15 s apart (:613-620).

WHY IT CANNOT PASS ON THIS STACK — my own checks, not theirs:
- Sharpest counterexample: a night at 5 s cadence with ONE 40-second reconnect hole passes the OUTPUT safety gate `timelineHasDenseLocalEvidence` (:564-591; coverage ≈99.9% ≥ 0.85, maxGap 40 ≤ 90) but is rejected wholesale by the INPUT gate. `merge` (:497-520) only joins runs ≤1 s apart, so output coverage is measured honestly — the output gate is sufficient and the input gate is redundant at 6× the strictness.
- The repo's own test asserts the design i

_Corrections:_ Their mechanism stands. Four corrections and two additions.

CORRECTION 1 (their edge-check claim is wrong on the path that matters). They assert ":609-610 edge checks fail on ordinary journal lead-in/lead-out" because "the sleep window's own bounds are session bounds, not sample bounds." Session bounds ARE sample bounds: `snapshotSession` computes `let start = first.t` (AtriaBLEManager.swift:42580) and constructs `SavedSession(id:, start: start, end: last.t, ...)` (:42686), with `points` stored as offsets from that same origin. So for an auto-clustered candidate, `cluster.first.start` == first HR sample and `cluster.last.end` == last HR sample, and the two edge checks pass exactly. The edge check only bites on user-adjusted/manual windows and history-replayed sessions. Does not change the verdict — the per-pair 15 s check and the 6/min count bar are the live blockers.

CORRECTION 2 (brief-gap-credit is a marker, not the cause). `briefGapCredit` (Sessions.swift:44836-44846, constant :5075) feeds `totalDuration`, which is an admission/duration quantity; the STAGING window is the span `[cluster.first.start, cluster.last.end]` (:44881). What makes the night unstageable is the inter-session hole itself sitting inside that span with no samples. Their conclusion is still right for the right reason: an inter-session gap exists only because the journal split at ≥90 s (activeJournalSegmentGapLimit), so any credited gap is ≥90 s ≫ 15 s.

CORRECTION 3 (line drift). Motion sufficiency is AtriaRecoveredMotionAnalytics.swift:187-191, not 189-193. Cluster bounds are Sessions.swift:44881, not 44882. The launch backfill function begins at Sessions.swift:41604, not 41605.

CORRECTION 4 (they under-count the opt-in lanes). Two more production lanes already pass `allowHROnlyEstimate: true` and were omitted from their list: Sessions.swift:38961 (user-initiated confirmed-sleep save) and Sessions.swift:39274 (HR-only confirm). Both still die at the same density gate, which strengthens rat


---

### Item 11 — real-defect (refuted 0/2, confidence high)

**Root cause**

The catch-up-marker hypothesis is REFUTED, but the underlying shape of the complaint is confirmed by a different mechanism: no physiological event in Atria schedules its own notification. `catchUpMarkerFrontierKey` (Atria/Atria/AtriaEventNotificationScheduler.swift:23) is read at exactly one site, :144, and feeds only `AtriaCatchUpCompletionPolicy.passAction` (Atria/Atria/AtriaNotificationCategories.swift:363-386), which drives only the "Catch-up complete" banner at :154-165. Nothing in the sleep / nap / workout / journal paths ever reads it. Its device value equalling drainedThroughUnix is just `.recordMarker` (AtriaEventNotificationScheduler.swift:150-151) noting the current backlog. Five independent real defects produce the reported behaviour:

(1) PASS-BOUND, NOT EVENT-BOUND. `sleep_review` ("Review last night" / "Review your nap") and `workout_review` ("Workout found") decisions exist only inside `LocalNotificationScheduler.schedule(...)` (Atria/Atria/LocalNotificationScheduler.swift:1107-1146). That function is reachable only from `scheduleFromLaunchIfRequested` (:591) — wired at Atria/Atria/AtriaApp.swift:1080 (launch) and :561 (`scene_active`) — and `scheduleBackgroundReviewPass` (:644) at AtriaApp.swift:836 (BGTask). Both decisions carry `delay: 6` (LocalNotificationScheduler.swift:1639 and :1750), i.e. 6 seconds after the PASS, with no relation to the event timestamp. The physiological moment is never a scheduling trigger.

(2) DISCOVERY IS FOREGROUND-ONLY, so the pass has nothing to notify about. `SessionStore.shouldEnqueueSleepReviewProjection` (Atria/Atria/Sessions.swift:33488-33500) hard-requires `applicationIsActive`; `scheduleSleepReviewCacheRefresh` (Sessions.swift:33616-33648) therefore just sets `sleepReviewRefreshDeferredUntilForeground = true` and returns when backgrounded. The dedicated background nap-catcher `runResidentSleepReviewRefreshIfUseful` (Sessions.swift:27906-27916 — whose own comment cites the on-device 14:05-16:40 nap that produced no detection) routes straight into that gate and dead-ends. In the BG/cold pass `makeSleepReviewDecision` falls back to `persistedPendingSleepReviewForNotification` (LocalNotificationScheduler.swift:1508-1515 → Sessions.swift:33596-33614), which can only re-read a receipt a PRIOR FOREGROUND projection wrote via `AtriaPendingSleepReviewStore.save` (LocalNotificationScheduler.swift:1556). A brand-new nap or night therefore returns `reason = "sleep_review_projection_deferred"`, `shouldSchedule: false` (:1523-1538 with :1797-1805). Net: the notification cannot fire until you open the app.

(3) IT FIRES WHILE YOU ARE ALREADY IN THE APP. `schedule(...)` has no application-state guard (contrast `guard !applicationIsActive` at AtriaEventNotificationScheduler.swift:76, :156, :171), and the delegate returns `[.banner, .sound]` unconditionally (LocalNotificationScheduler.swift:2405-2412). So the "Review last night" / "Workout found" banner lands ~6 s AFTER the user foregrounds Atria — literally the one moment it is useless. This is precisely "the push notification lies there, but never shows up at right time".

(4) WORKOUT-DETECTED IS HARD-SUPPRESSED ON THIS DEVICE, AND HAS BEEN FOR 13 DAYS. `reviewNotificationsProtectedByLiveCapture` (LocalNotificationScheduler.swift:1783-1787) returns `ble.status == .connected && ble.rangeLossBackfillPending && ble.sessionSampleCount > 0`. `rangeLossBackfillPending` is `@Published` straight off `OfflineSyncDefaults.rangeLossBackfillPending` (Atria/Atria/AtriaBLEManager.swift:979) — the device value is TRUE, requested 2026-08-06. BOTH workout paths gate on it: `makeWorkoutReviewDecision` (:1678) and the retry `scheduleWorkoutReviewAfterCachePublicationIfNeeded` (:922). While the strap is worn, connected and streaming — the normal wear state, including the 21:42:50 `workout_start_boundary` journal close — every workout notification is dropped with `reason: "live_capture_protected_range_loss_backfill"`, and :1679 additionally WIPES `workoutReviewLastCandidateIDKey`, destroying the dedup receipt. That single sticky flag explains "workout detected — never shows" completely.

(5) "NAP DETECTED" DOES NOT EXIST, AND THE JOURNAL PROMPT IS A CLOCK ALARM. The only event-time push in the whole app is `scheduleSleepLogged`, and Sessions.swift:37418 restricts it to `candidate.kind != "nap_candidate"` — naps are excluded by construction, so there is no nap push at all beyond the pass-bound "Review your nap" (LocalNotificationScheduler.swift:1641-1643). For "Start the day with Journal": `scheduleMorningJournalCheckIn` (LocalNotificationScheduler.swift:448-538) targets `morningNudgeMinutes(windowEnd:)` (:434) computed from `DutyCycleDefaults.sleepWindowEndMin` at :481 — a value written at Sessions.swift:41400-41421 as the MEDIAN wake of the last 14 overnight confirmed sleeps + 60 min. So the nudge lands at median-wake+15 no matter when you actually woke. The richer wake-anchored summary (`scheduleMorningSummaryIfNeeded`, Sessions.swift:12841-12912) needs a fully materialized metric (recovery + hrv + sleepDuration, :12864-12874) inside `isWithinMorningSummaryWindow` = wake+4 h with a hard 14:00 cap (:12826-12838), so a drain/projection lag over 4 h silently drops it for the day (:12884-12889 logs `outside_window`).

STARVATION COMPONENT (partial, aggravator only): `runResidentMorningSettlementIfUseful` and `runResidentSleepReviewRefreshIfUseful` are both driven from `SessionStore.checkpoint(_:)` (Sessions.swift:27767-27768), which only runs on live HR sample checkpoints. With zero HR from 21:56:32 onward, neither ran for the whole 4 h dead window. But even when they do run, path (2) dead-ends them at the foreground gate — so the stall makes it worse, it is not the cause.

**Evidence**

- Atria/Atria/AtriaEventNotificationScheduler.swift:23 — catchUpMarkerFrontierKey declared; read ONLY at :144, consumed ONLY by the catch-up banner at :154-165. Refutes the marker-frontier hypothesis for sleep/nap/workout.
- Atria/Atria/AtriaNotificationCategories.swift:363-386 — AtriaCatchUpCompletionPolicy.passAction is the sole consumer of the marker; its Action enum only ever yields the 'Catch-up complete' notify.
- Atria/Atria/LocalNotificationScheduler.swift:1107-1146 — private static func schedule(...): the ONLY producer of sleep_review + workout_review decisions.
- Atria/Atria/AtriaApp.swift:561 — scheduleProductionNotificationMaintenance(reason: "scene_active"); AtriaApp.swift:1080 and :1230 (launch); AtriaApp.swift:836 (BGTask scheduleBackgroundReviewPass). These are the only three edges that can post a review notification.
- Atria/Atria/LocalNotificationScheduler.swift:1639 — sleep_review `delay: 6`; :1750 — workout_review `delay: 6`. Six seconds from the PASS, not from the event.
- Atria/Atria/Sessions.swift:33488-33500 — shouldEnqueueSleepReviewProjection requires `applicationIsActive`; no background admission exists.
- Atria/Atria/Sessions.swift:33616-33648 — scheduleSleepReviewCacheRefresh sets sleepReviewRefreshDeferredUntilForeground = true and returns when the gate fails.
- Atria/Atria/Sessions.swift:27906-27916 — runResidentSleepReviewRefreshIfUseful (the explicit background nap-catcher, comment at :27893-27905 cites the on-device 14:05-16:40 nap) calls the gated refresh and is therefore inert while backgrounded.
- Atria/Atria/LocalNotificationScheduler.swift:1508-1515 + Atria/Atria/Sessions.swift:33596-33614 — the cold/BG fallback only re-reads AtriaPendingSleepReviewStore, written at LocalNotificationScheduler.swift:1556 by a prior foreground pass. New events have no receipt.
- Atria/Atria/LocalNotificationScheduler.swift:1783-1787 — reviewNotificationsProtectedByLiveCapture = connected && rangeLossBackfillPending && sessionSampleCount > 0.
- Atria/Atria/AtriaBLEManager.swift:979 — @Published rangeLossBackfillPending is initialized/held from OfflineSyncDefaults.rangeLossBackfillPending; device value TRUE since 2026-08-06 (13 days).
- Atria/Atria/LocalNotificationScheduler.swift:1678 and :922 — both workout_review paths gate on that flag; :1679 removeObject(forKey: workoutReviewLastCandidateIDKey) wipes the dedup receipt on every suppression.
- Atria/Atria/LocalNotificationScheduler.swift:2405-2412 — willPresent returns [.banner, .sound] unconditionally; schedule(...) has no applicationState guard, unlike AtriaEventNotificationScheduler.swift:76/:156/:171.
- Atria/Atria/Sessions.swift:37418 — `if candidate.kind != "nap_candidate", firstSavedOvernight == nil` gates the only event-time push (scheduleSleepLogged at :37457 and :38323): naps never get one.
- Atria/Atria/LocalNotificationScheduler.swift:434 morningNudgeMinutes + :481-:492 target computation, backed by Atria/Atria/Sessions.swift:41400-41421 writeDutyCycleSleepWindow = MEDIAN wake over last 14 overnights + 60 min. The journal nudge is a median-clock alarm.
- Atria/Atria/Sessions.swift:12826-12838 isWithinMorningSummaryWindow (wake+4h, hard 14:00 cap) and :12864-12874 (requires recoveryPercent + hrv + sleepDuration) — the wake-anchored summary is dropped when materialization lags >4h past wake.
- Atria/Atria/Sessions.swift:27767-27768 — runResidentMorningSettlementIfUseful / runResidentSleepReviewRefreshIfUseful are driven from checkpoint(_:), i.e. live HR samples only; the 4h HR silence starved both.
- Device: offlineSync.rangeLossBackfillPending=true requested 2026-08-06; activeJournal.lastClose 2026-08-18 21:42:50 reason=workout_start_boundary (a real workout boundary during connected+streaming wear → suppressed by :1783).
- Device: notification.sleepEvent.lastKind='morning_summary' lastDurationMinutes=303 for 2026-08-18 confirms the rich summary fired that day and, via shouldSkipRedundantSleepEvent (LocalNotificationScheduler.swift:1058-1065), then suppressed the 'Sleep logged' event push for the same duration.
- Grep of Atria/Atria/Sessions.swift for `LocalNotificationScheduler.` yields only :12269, :12869, :12896, :12905, :26234, :33227, :37457, :38323 — the sleep-review projection completion never re-runs a notification pass, so a candidate that materializes after a scene_active pass waits for the next app edge.

**Proposed fix**

Five bounded changes, ordered by user-visible impact.

A. UNBLOCK "workout detected" (highest impact; single-flag fix). Atria/Atria/LocalNotificationScheduler.swift:1783-1787: `rangeLossBackfillPending` is a 13-day-sticky ticket, not a statement that THIS candidate's window is still filling. Replace the blanket guard with a candidate-local freshness test — extract a `nonisolated static func workoutReviewIsProtectedByLiveCapture(linkConnected:backfillPending:backfillRequestedAt:backfillLastProgressAt:sessionSampleCount:candidateEnd:now:) -> Bool` that suppresses only when the backfill is actively progressing (last progress within ~10 min) AND the candidate's own window overlaps the unfilled range. Also stop wiping the dedup receipt on suppression: delete `defaults.removeObject(forKey: workoutReviewLastCandidateIDKey)` at :1679 (a suppressed decision must not erase what the user was already told).

B. BIND TO THE EVENT, NOT THE PASS. Add `LocalNotificationScheduler.scheduleSleepReviewForCandidate(_:)` / `scheduleWorkoutReviewForCandidate(_:)` that run the same dedup/budget/quiet-hours plumbing and call them at materialization: Atria/Atria/Sessions.swift:37451-37457 (auto-confirm commit) and at the sleep-review projection publication inside `scheduleSleepReviewCacheRefresh` (Sessions.swift:33650+), plus the workout candidate materialization that feeds AtriaHomeView.swift:1294. `schedule(...)` then becomes catch-up-only, not the primary route.

C. LET DISCOVERY RUN WHILE BACKGROUNDED. Atria/Atria/Sessions.swift:33495-33497: relax `applicationIsActive` to `applicationIsActive || boundedBackgroundLeaseIsHeld`, threading the same bounded CPU/thermal lease already used by `requestBackgroundArchiveProjectionIfSafe` (AtriaApp.swift:852-862), so `runResidentSleepReviewRefreshIfUseful` (Sessions.swift:27906) actually performs its documented job instead of setting a deferral flag.

D. STOP BANNERING THE USER WHO IS ALREADY IN THE APP. Add `guard UIApplication.shared.applicationState != .active` around the sleep_review/workout_review decisions in `schedule(...)` (Atria/Atria/LocalNotificationScheduler.swift:1142-1145), mirroring AtriaEventNotificationScheduler.swift:76 — the in-app card owns the foreground state.

E. ANCHOR THE JOURNAL PROMPT TO THIS MORNING'S WAKE. Schedule the journal nudge from the wake-boundary/auto-confirm commit (Atria/Atria/Sessions.swift:38323 and :37457) with a small delay off `confirmed.end`, and demote the median-clock path at LocalNotificationScheduler.swift:481-492 to a fallback that only fires if no wake was detected by median-wake + 2 h. Separately, give naps their own event push by lifting the `candidate.kind != "nap_candidate"` restriction at Sessions.swift:37418 into a distinct `nap_logged`/`nap_review` category (AtriaNotificationCategory already has the toggle scaffolding at AtriaNotificationCategories.swift:15-60).

**Test plan**

Repo idiom is pure `nonisolated static` policy helpers exercised by XCTest under scheme AtriaTests (see AtriaEventNotificationPolicyTests.swift, AtriaSleepReviewNotificationDebounceTests.swift, AtriaMorningSummaryWindowTests.swift, AtriaPolicyMathTests.swift:350-360). `reviewNotificationsProtectedByLiveCapture` currently has ZERO test coverage — grep of Atria/AtriaTests returns no hits.

1. New Atria/AtriaTests/AtriaWorkoutReviewNotificationAdmissionTests.swift, against the extracted helper from fix A. Reproduces the device state exactly: `backfillPending: true, backfillRequestedAt: 2026-08-06, backfillLastProgressAt: nil, linkConnected: true, sessionSampleCount: 8066, candidateEnd: now-20min` must assert FALSE (not protected) — this test FAILS on today's code, which returns true. Companion case: an actively-progressing backfill (`backfillLastProgressAt: now-2min`) whose unfilled range covers `candidateEnd` asserts TRUE.

2. Extend Atria/AtriaTests/AtriaSleepReviewCacheTests.swift (existing shouldEnqueueSleepReviewProjection block at :990-1051): add a case asserting the projection is admitted with `applicationIsActive: false, boundedBackgroundLeaseHeld: true`, so a nap discovered while backgrounded is not deferred. Note :1800 asserts the implementation string contains "shouldEnqueueSleepReviewProjection" — that source-scan pin must be updated with the signature change.

3. New pure helper + test for fix E: `LocalNotificationScheduler.journalNudgeTarget(detectedWake:medianWakeMinutes:now:)`. Assert that with detectedWake 09:10 and medianWakeMinutes 06:30 the target is 09:10+delay, not 06:45; and that with `detectedWake: nil` past medianWake+2h it falls back to the median clock. Extends the existing morningNudgeMinutes cases in AtriaPolicyMathTests.swift:350-360.

4. New pure `shouldPostReviewBanner(applicationIsActive:)` asserted false when active (fix D), added to AtriaNotificationCategoryTests.swift alongside the existing honesty scans.

5. Regression pin for fix A's second half: assert that a suppressed workout decision leaves `workoutReviewLastCandidateIDKey` intact (today LocalNotificationScheduler.swift:1679 clears it).

**Noticed nearby**

Four adjacent problems found while tracing this, none of which are item 11 itself:

1. SILENT DROP OF QUIET-HOURS-DEFERRED REVIEWS. Atria/Atria/LocalNotificationScheduler.swift:1137 unconditionally calls `center.removePendingNotificationRequests(withIdentifiers: Identifier.removable)` at the top of every pass. A sleep_review deferred to wake by `quietHoursAdjustedDelay` (:1985-2013) — e.g. scheduled 03:00 for 07:00 delivery — is destroyed by ANY app open before 07:00, and is then blocked from rescheduling by the 4 h `sleepReviewReminderCooldown` (:41) and `sleepReviewMaximumSchedulesPerCandidate = 2` (:42). The user can silently burn both of a candidate's two allowed schedules without ever seeing a banner. This deserves its own item.

2. THE RICH MORNING SUMMARY IS GATED ON AN 8-DAY-STALE HRV. Atria/Atria/Sessions.swift:12864-12874 requires `metric.hrv` non-nil. Device shows `hrv.lastReadyAnalysisAt = 2026-08-11` (8 days ago) and `lastNormalWearAnalysisAttemptAt = 2026-08-15`. On any day where HRV never materializes, the summary bails with `awaiting_confirmed_sleep_metric` and only the median-clock plain nudge survives — which is exactly the "wrong time" the user describes. Relevant to items 8/10 as well.

3. THE WORKOUT RETRY PATH IS DOUBLY FOREGROUND-BOUND. `scheduleWorkoutReviewAfterCachePublicationIfNeeded` is invoked only from `handleDashboardRevisionUpdate` (Atria/Atria/AtriaHomeView.swift:1289-1298), a SwiftUI onChange hook that cannot fire while the scene is suspended. So even without the sticky-flag bug in (4), the workout retry never runs in background.

4. THE 6/DAY SHARED ATTENTION BUDGET IS A REAL SUPPRESSOR. LocalNotificationScheduler.swift:1942-1976, exempting only diagnostic/battery/bluetooth_off. On a day with fit_check (own cap 2/day, :2020-2038), sync_nudge, battery and a morning summary, the sleep_review and workout_review can be silently `suppressed_budget`. Device `notification.fitcheck.lastAt = 2026-08-17` shows fit_check is not currently the culprit, but the shared-budget design means the two most important physiological notifications sit at the BACK of the queue behind device-health chatter.

**Challenger 1 — refuted=False**

I verified essentially every cited file:line against the real code on branch codex/whoop-remaining-product-gaps (HEAD 47538c32). The claim's mechanisms hold; the line numbers are accurate; the marker refutation is correct (catchUpMarkerFrontierKey appears at exactly 4 sites — :23 declare, :144 read, :151/:153/:155 write/clear — and feeds only AtriaCatchUpCompletionPolicy.passAction and the catch-up banner). Nothing in the sleep/nap/workout paths touches it. I therefore cannot refute the claim, and mark refuted=false — but three material corrections are needed.

CONFIRMED BY READING:
(1) schedule(...) at LocalNotificationScheduler.swift:1107 is the only producer of sleep_review/workout_review decisions; reachable only from scheduleFromLaunchIfRequested (:591, wired at AtriaApp.swift:1080 and :1230) and scheduleBackgroundReviewPass (:644, wired at AtriaApp.swift:836), plus scene_active via scheduleProductionNotificationMaintenance (AtriaApp.swift:561). delay: 6 confirmed at :939, :1639, :1750.
(3) grep for "applicationState" in LocalNotificationScheduler.swift returns ZERO hits — the file has no application-state guard at all, in contrast to AtriaEventNotificationScheduler.swift:76, :156, :171 which I read and confirmed. willPresent at :2406-2412 returns [.banner, .sound] unconditionally.
(4) Verified the full lifecycle: markRangeLossBackfillRequired (AtriaBLEManager.swift:16329-16338) sets the ticket; reconcileRangeLossBackfillPendingWithArchive (:16257-16262) refuses to clear while AtriaHistoricalGapLedger.hasPendingWindows is true, so a permanently unfillable gap latches it forever. The only other clears are user "Start fresh" (:16174) and verified strap-reset reconciles (:6087, :6189, :9555). The repo's own field report standing note (.claude/field-report-2026-08-19.md:180-185) documents rangeLossBackfillPending=true since 2026-08-06 AND a second reason the stale-armed reconciliation can never fire (live status gap_retained_transaction_unverified is not in the clearing set).
(5) Sessions.swift:37418 confirmed verbatim; sleepReviewNotificationTitle (:1645-1647) confirms "Review your nap" is the only nap-facing string. writeDutyCycleSleepWindow (Sessions.swift:41399-41420) is median-of-14 wake +60; morningNudgeMinutes (:434) computes windowEnd−45, i.e. median wake +15. Confirmed.
Starvation: refreshSessionDerivedCachesAfterUpsert is called from checkpoint with scheduleSleepReviewRefresh: false (Sessions.swift:27753-27758), so a live checkpoint does NOT eve

_Corrections:_ THE CLAIM STANDS. Three corrections — one weakens item (2), one strengthens item (4), one makes proposed fix D dangerous as written.

=== CORRECTION 1 — item (2) is OVERSTATED. "The notification cannot fire until you open the app" is false. ===
makeSleepReviewDecision has a SECOND admission source the claim omits. LocalNotificationScheduler.swift:1520-1523:

    let reviewableSnapshotNight = sleepReviewSnapshotFallback(
        preparedIsLoading: preparedIsLoading,
        snapshotNight: snapshot.latestReviewable)
    guard let latest = latestReviewNight ?? reviewableSnapshotNight, latest.confirmed == false else { ... }

sleepReviewSnapshotFallback (:1808-1814) admits any unconfirmed snapshot.latestReviewable while the foreground cache is loading — the in-code comment at :1663-1667 says so explicitly ("can legitimately see a reviewable daily snapshot while the heavier foreground cache is still rebuilding"). That snapshot is store.sleepHistorySnapshot, whose unconfirmed candidate nights are built from rollups (Sessions.swift ~54345-54360, `confirmed: false`, source `sleep_candidate`) by refreshHistorySnapshotCache (Sessions.swift:10816) — which is gated ONLY on projection lanes (historySnapshotProjectionShouldDefer), NOT on applicationIsActive. And AtriaApp.swift:809 awaits waitForDeferredSessionLoadIfNeeded before the BG review pass; that load ends with requestRecoveredDataRecomputation("deferred_session_load") (Sessions.swift:22967) which publishes a fresh sleepHistorySnapshot (Sessions.swift:17502).
So on a cold BGTask launch the sleep_review notification CAN be produced with no prior foreground, and the "sleep_review_projection_deferred" reason only occurs when snapshot.candidateCount == 0 (:1792-1798).
CORRECTED STATEMENT: two discovery lanes exist. The daily-ROLLUP lane is background-capable; the richer sleep-review PROJECTION lane (nap-aware, stage-level, pendingSleepReviewNightForUI + napReviewCandidateNightsForUI) is foreground-only. Background review discov

**Challenger 2 — refuted=False**

I re-derived this from source and reached the same core conclusion, then found two additional mechanisms they missed and one factual overstatement.

CATCH-UP HYPOTHESIS — INDEPENDENTLY REFUTED (agree). `catchUpMarkerFrontierKey` (Atria/Atria/AtriaEventNotificationScheduler.swift:23) has exactly four references, all inside `runSyncEventObservation` (:141-166), feeding only `AtriaCatchUpCompletionPolicy.passAction` (Atria/Atria/AtriaNotificationCategories.swift:363-386) → the "Catch-up complete" banner (:154-165). `grep -rn catchUpMarkerFrontier|markerFrontier` over the whole target returns nothing in any sleep/nap/workout/journal path. The device value 2026-08-18 21:22:38 == drainedThroughUnix is just the `.recordMarker` branch (:150-151) noting a >4 h backlog. Confirmed refuted.

THEIR FIVE MECHANISMS — ALL VERIFIED BY ME INDEPENDENTLY.
(1) `sleep_review`/`workout_review` exist only as decisions inside the private `schedule(...)` (LocalNotificationScheduler.swift:1107); `grep` shows exactly two callers, :614 (`scheduleFromLaunchIfRequested`) and :645 (`scheduleBackgroundReviewPass`), wired at AtriaApp.swift:1066+1076 (launch/`scene_active` via `scheduleProductionNotificationMaintenance`, :561) and :836 (BGTask). Both decisions carry `delay: 6` (:1639, :1750) — six seconds after the PASS, unrelated to the event.
(2) Discovery is foreground-only: `shouldEnqueueSleepReviewProjection` hard-requires `applicationIsActive` (Sessions.swift:33487-33499); `scheduleSleepReviewCacheRefresh` sets `sleepReviewRefreshDeferredUntilForeground = true` and returns otherwise (:33637-33648). The dedicated background nap-catcher `runResidentSleepReviewRefreshIfUseful` (:27906-27916) routes straight into that gate — its own comment cites the on-device 14:05-16:40 nap that produced no detection. `napReviewCandidateNightsForUI` is written only at Sessions.swift:33857, inside the projection completion.
(3) No app-state guard: `schedule` (:1107) and `add` (:2039) never check `applicationState` (contrast the explicit `guard !applicationIsActive` at AtriaEventNotificationScheduler.swift:76/156/171), and the delegate returns `[.banner, .sound]` unconditionally (LocalNotificationScheduler.swift:2407-2412).
(4) Workout hard-suppressed: `reviewNotificationsProtectedByLiveCapture` = `connected && rangeLossBackfillPending && sessionSampleCount > 0` (:1783-1787); `rangeLossBackfillPending` is `@Published` off the raw default (AtriaBLEManager.swift:979) and is TRUE on device since 2026-08-06.

_Corrections:_ Their mechanism stands; it is incomplete on two material points and overstated on one.

CORRECTION A (overstatement). "No physiological event in Atria schedules its own notification" is false. Two do: `scheduleSleepLogged` fires from the auto-confirm commit (Sessions.swift:37457, :38323), and `scheduleMorningSummaryIfNeeded` fires from metric materialization (:12267 → :12841). The accurate claim is narrower and worse: those event-triggered schedules exist, but their DELIVERY TIME is re-clamped to a learned median clock, and the event-derived ones get destroyed before delivery (B and C below).

CORRECTION B — THE DEEPER UNIFYING CAUSE THEY MISSED: the whole morning stack is clocked off the learned MEDIAN duty-cycle window, not tonight's actual wake. `writeDutyCycleSleepWindow` sets `sleepWindowEndMin = median wake + 60` over the last 14 overnights (Sessions.swift:41415-41419). Four independent sites then bind to it:
  - `quietHoursAdjustedDelay` (LocalNotificationScheduler.swift:1985-2013) computes `quietEnd = windowEnd - 60` = median wake and DEFERS every non-exempt notification landing before it (`sleep_review` and `workout_review` are not in `budgetExemptKinds`, :1943). It is applied inside `add` at :2081. So "Review last night", scheduled at a real 06:00 wake with a median wake of 07:30, is pushed to 07:30.
  - `scheduleMorningSummary` independently clamps forward to `wakePlus15 = median wake + 15` (:296-306) — so even the wake-anchored rich summary is delivered on the median clock. They attributed the summary's failure only to the 4 h window; this second clamp is separate and fires on every early wake.
  - `morningNudgeMinutes` (:434-436) — the plain journal nudge, as they said.
  - `shouldAttemptResidentMorningSettlement` (Sessions.swift:27866-27884) admits the background wake-settlement only in `[windowEnd, windowEnd + 5 h]` = [median wake + 1 h, +6 h]. So the background path that produces "Sleep logged" and the morning metric cannot even RUN at an actual wake


---

### Item 12 — real-defect (refuted 0/2, confidence high)

**Root cause**

Three independent, compounding defects — none of them caused by the 4 h stall.

(a) RETENTION NEVER EXECUTES — a hard-coded release kill switch. The entire retention/compaction graph has exactly one production entry point: `SessionStore.compactHistoricalArchiveIfUseful` (Atria/Atria/Sessions.swift:25904) → `HistoricalArchive.compactArchiveConverging` (Sessions.swift:26024). Its first statement is `guard Self.shouldExecuteArchiveWideMaintenance(explicitDebugOverride:)` (Sessions.swift:25926), and that function is literally `{ explicitDebugOverride }` (Sessions.swift:25645-25648). `explicitDebugOverride` is true only when `reason == "debug_launch_arg"` AND the process was launched with `--atria-compact-archive` (Sessions.swift:25904-25908, 51339-51341). The real BGProcessing caller passes `reason: "bg_processing"` (AtriaApp.swift:886), so on a user's phone the driver always falls into `reserved_automatic_execution_disabled` and returns before touching anything. `shouldAdmitAutomaticArchiveCompaction` (Sessions.swift:25617) — the full thermal/battery/background admission model — is dead code behind that fence. So `AtriaHistoricalRetentionPolicy.production` (14-day raw horizon, 512 MiB cap; AtriaHistoricalRetentionPolicy.swift:9-12) has never once been evaluated on this device. The second half of the blocker string is also real and independent: the cold-session tier ships `consumerReadiness: .shadowOnly` and `productionRawRetirementEnabled: false` hard-coded (AtriaColdSessionMigration.swift:157-158), with six `.unsupported(...)` reasons (AtriaColdSessionStore.swift:39-46) and `authorizesRawRetirement` requiring all six `.available`.

(b) RAW IS UNCOMPRESSED BECAUSE NOTHING EVER COMPRESSES IT. `AtriaHistoricalSealedJSONLCompression.commit(chunkID:...)` (AtriaHistoricalSealedJSONLCompression.swift:90) has ZERO production call sites — every caller in the repo is a test (AtriaHistoricalSealedJSONLCompressionTests, AtriaHistoricalArchiveCatalogTests, AtriaHistoricalJSONLRecentScannerTests, AtriaHistoricalRetentionConsumerCutoverTests, etc.). The "compressed cutover" that landed is READER-side only: the catalog can resolve a `compressedStorage` row (AtriaHistoricalArchiveCatalog.swift:407-468), scanners skip `.atria-deflate` (AtriaHistoricalJSONLRecentScanner.swift:19), and the retirement executor refuses compressed chunks (AtriaHistoricalRawRetirementExecutor.swift:87-90). No producer was ever wired, and the only place it could have been called from is the compaction graph that (a) fences off. Note: chunk ROTATION is healthy — `productionMaximumActiveBytes = 4 MiB` (AtriaHistoricalArchiveCatalog.swift:119) matches the device's 2986.5 MB / 686 files = 4.35 MB per file. The report's "32 MB each" and the manifest's `rotationThresholdBytes=134217728` are both wrong/stale: that 128 MiB value is the LEGACY daily-segment constant (HistoricalArchive.swift:34) still stamped into `RotationManifest` at HistoricalArchive.swift:7529-7534, dead metadata for a path the catalog replaced.

(c) THE 2.13 GB OF DEDUPE BOOKKEEPING HAS A PRUNE PATH THAT IS STRUCTURALLY UNREACHABLE — this is the worst defect. `historical-archive.identity.jsonl` is append-only (`appendIndex`, AtriaHistoricalArchiveDurableStore.swift:1668-1700), one JSON line per admitted frame, whose `key` hex-encodes THE ENTIRE FRAME PAYLOAD (`stableKey`, :86-98) — so the index costs ~2× the raw payload in hex. The ONLY code that shrinks the file is `rebuildDerivedIndex` (:1742-1776, whole-file temp+replace). `pruneExpiredIdentitiesLocked` (:745-771) reaches that rebuild only past `guard fullyMaterializedIdentityIndex else { …remove from in-memory dictionary only…; return }` (:760-764). And `fullyMaterializedIdentityIndex` is set FALSE at init whenever the existing index exceeds `productionMaximumEagerIdentityIndexBytes = 8 MiB` (:29-30, :364-372). The device's index is 1290.2 MB. This is a permanent self-latch: past 8 MiB the file can never be compacted again, at any launch, forever. The SQLite accelerator does get `DELETE FROM … WHERE observed_unix < ?` (AtriaHistoricalLiveIdentityLookup.swift:278-289) — but the pragma block (:89-105) sets no `auto_vacuum` and nothing ever runs `VACUUM`, so deleted pages go to the freelist and the 839.7 MB file never shrinks. Worse, the prune is only attempted inside `flush()` on a ≥6 h cadence (:704-712) whose clock `lastPruneAtUnix` is reset to `now()` in every `init` (:337) — i.e. every process launch — so on a phone that relaunches often it may effectively never fire at all. Finally this bookkeeping is counted as `replay_evidence` in the cap (AtriaHistoricalHighVolumeStoragePlanner.swift:64-72) against a 512 MiB ceiling (:282): at 1.29 GB, retiring EVERY raw chunk still leaves projected > cap, so `plan.state` would be `.blocked` even with the (a) fence removed.

Why it is not "starved by the 4 h stall": the fences are compile-time/structural, not runtime-starved. The stall is only a secondary aggravator — aggregate materialization (`materializeNextSealedCatalogDependency`, HistoricalArchive.swift:1451) runs ONLY from the full-drain terminal path in AtriaBLEManager.swift:38038, gated on coverage status; with `authority=gapResolvedConsumersPending` and `terminalArchiveFailureDiagnostic=publicationCheckpointMissing` since 08-14, only 227 aggregates exist for 686 raw chunks, so even an unfenced retention pass would find ~2/3 of chunks ineligible (`committedChunkIDs`, HistoricalArchive.swift:9525-9540).

**Evidence**

- Atria/Atria/Sessions.swift:25645 — `nonisolated static func shouldExecuteArchiveWideMaintenance(explicitDebugOverride: Bool) -> Bool { explicitDebugOverride }` — the whole release fence, no environmental input at all
- Atria/Atria/Sessions.swift:25926 — `guard Self.shouldExecuteArchiveWideMaintenance(explicitDebugOverride:) else { reserveArchiveCompactionForSafeBackground(); …status=reserved_automatic_execution_disabled…; return }` precedes every archive read
- Atria/Atria/Sessions.swift:25904 — `explicitDebugOverride = reason == "debug_launch_arg" && ProcessInfo.arguments.contains("--atria-compact-archive")`
- Atria/Atria/AtriaApp.swift:886 — the real BGProcessing task calls `store.compactHistoricalArchiveIfUseful(reason: reason, backgroundLease: lease)` with a bg reason, so it can never satisfy the fence
- Atria/Atria/Sessions.swift:51339 — `if ProcessInfo…contains("--atria-compact-archive") { compactHistoricalArchiveIfUseful(reason: "debug_launch_arg") }` — the sole executing lane
- Atria/Atria/Sessions.swift:25617 — `shouldAdmitAutomaticArchiveCompaction(...)` full thermal/battery/background model, unreachable behind the fence
- Atria/Atria/AtriaHistoricalRetentionPolicy.swift:9 — `.production` = rawHorizon 14 days, maximumRawBytes 512 MiB — the policy exists and has never run on device
- Atria/Atria/AtriaManagedStorageInventory.swift:199 — `RETENTION_EXECUTION_BLOCKED(automatic_execution_disabled+cold_session_consumers_shadow_only)`
- Atria/Atria/AtriaColdSessionMigration.swift:157 — `consumerReadiness: .shadowOnly, productionRawRetirementEnabled: false` hard-coded at catalog construction
- Atria/Atria/AtriaColdSessionStore.swift:39 — `.shadowOnly` = six `.unsupported(...)`; `authorizesRawRetirement` requires all six `.available` (:62)
- Atria/Atria/AtriaHistoricalSealedJSONLCompression.swift:90 — `func commit(chunkID:...)`; grep for callers in Atria/Atria/*.swift returns only the declaration — every invocation lives in Atria/AtriaTests/
- Atria/Atria/AtriaHistoricalArchiveCatalog.swift:119 — `productionMaximumActiveBytes: UInt64 = 4 * 1024 * 1024`; seal at :261 `if crossedDay || actualBytes >= maximumActiveBytes` — matches 2986.5 MB / 686 = 4.35 MB/file
- Atria/Atria/HistoricalArchive.swift:34 — `private static let rotationThresholdBytes = 128 * 1024 * 1024` (legacy), written into RotationManifest at :7529 — explains the misleading 134217728 in the container
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:29 — `productionMaximumEagerIdentityIndexBytes: UInt64 = 8 * 1024 * 1024`
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:364 — `shouldUseBoundedColdLookup = liveIdentityLookup != nil && existingIndexBytes > maximumEagerIdentityIndexBytes` → `fullyMaterializedIdentityIndex = false` (:369) — permanently true for a 1.29 GB index
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:760 — `guard fullyMaterializedIdentityIndex else { for key in expired { statesByKey.removeValue(forKey: key) }; return … }` — on-disk index never rewritten
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:1742 — `rebuildDerivedIndex(with:)` is the only writer that shrinks identity.jsonl (temp file + `replaceItemAt`)
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:1668 — `appendIndex(_:batch:)` seeks to end and writes one line per frame; unbounded growth
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:86 — `stableKey` appends `payload.count` then the full `payload`, hex-encoded → index line ≈ 2× raw payload bytes
- Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:704 — prune only attempted inside `flush()` when `now - lastPruneAtUnix >= 6*60*60`; :337 `self.lastPruneAtUnix = now()` in init resets that clock every process launch
- Atria/Atria/AtriaHistoricalLiveIdentityLookup.swift:278 — `prune(observedBefore:)` issues `DELETE FROM … WHERE observed_unix < ?` only; :89-105 pragma block sets WAL/synchronous/temp_store/busy_timeout/wal_autocheckpoint/cache_size but NO auto_vacuum, and no `VACUUM` exists anywhere in the file → 839.7 MB high-water mark is permanent
- Atria/Atria/AtriaHistoricalHighVolumeStoragePlanner.swift:72 — `liveReplayIdentityIndexFilename = "historical-archive.identity.jsonl"` counted as replay evidence in the cap
- Atria/Atria/AtriaHistoricalHighVolumeStoragePlanner.swift:282 — `static let production = Self(maximumHighVolumeBytes: 512 * 1_024 * 1_024)`; plan() :396-388 → with 1.29 GB of replay evidence, `unresolved > 0` and `selections` empty ⇒ `.blocked`
- Atria/Atria/HistoricalArchive.swift:7602 — `catalogRawFileURLs()` returns `snapshot.chunks.filter { $0.state != .retired }` — a retired chunk vanishes from every reader's candidate list
- Atria/Atria/HistoricalArchive.swift:7353 — HR sidecar is consulted only for a URL already in `selected` whose catalog row is `.sealed`; a retired chunk's valid hr-index sidecar is never read (falls to `rawScan`, which returns nil ⇒ whole read fails closed)
- Atria/Atria/HistoricalArchive.swift:8883 — `loadRecentGravitySamplesUncached` tails `recentReadableFileURLs()` directly; no derived/motion-epoch fallback exists
- Atria/Atria/HistoricalArchive.swift:9050 and :9072 — `loadRecentHeartRateSamples(limit:)` / `(since:limit:)` iterate raw files only
- Atria/Atria/HistoricalArchive.swift:7166 — `metricHeartRatePoints` (exact-window HR used by AtriaHealthScreen, AtriaVitalsCollectionSections, AtriaActivityMonitor, Sessions) is raw-file-list driven with the sidecar only as an accelerator
- Atria/Atria/AtriaHistoricalAggregateChunk.swift:23-83 — the derived tier already carries HeartRateMinute (exact samplesByBPM / terminalBPMSeconds / transitionHalfBPMSeconds), RREpoch (sumNN, sumNN², adjacent-diff sums, pNN50 count, bridges), MotionEpoch (stillnessRatio, stepDelta, sleepStage) — everything the insight surfaces need
- Atria/Atria/AtriaHistoricalRawRetirementExecutor.swift:99 and Atria/Atria/HistoricalArchive.swift:1772,1842,2095,2165,2230,2358,2467,2522 — every `AtriaHistoricalAggregateReader` construction is inside the retention/cutover graph; no UI or SessionStore path reads aggregates-v2
- Atria/Atria/AtriaBLEManager.swift:38038 — `materializeNextSealedCatalogDependency` runs only on the full-drain terminal path gated on coverage status ∈ {historyComplete, coverageProven, gapResolvedConsumersPending, consumersCommitted}
- Atria/Atria/Sessions.swift:51561 — `AtriaManagedStorageInventory.measure()/recordReceipt(...)` writes truth only to UserDefaults key `atria.debug.managedStorageInventory.v1` (AtriaManagedStorageInventory.swift:38)
- Atria/Atria/AtriaSettingsView.swift:959 — Settings shows `"Storage · <total>"` with detail `DataCopy.storageDisclosure` (:108) about backup/export; it never states that retention is blocked and offers no purge control

**Proposed fix**

Five changes, ordered by bytes-per-risk. Nothing here deletes data any insight reader still needs.

FIX 1 (biggest win, lowest risk — 2.13 GB, touches no user data at all): make the dedupe bookkeeping bounded.
  1a. Atria/Atria/AtriaHistoricalArchiveDurableStore.swift:760 — remove the `guard fullyMaterializedIdentityIndex else { …in-memory only… }` early return from the COMPACTION side. Add a bounded, streaming `compactIdentityIndexOutsideHorizon(now:)`: read identity.jsonl line-by-line with the existing `forEachLine`-style 64 KiB reader, copy forward only lines whose `observedAtUnix >= now - identityRetention` into a temp file, then `replaceItemAt` exactly as `rebuildDerivedIndex` (:1742-1776) already does. This never needs the whole index in memory, so it is legal in the bounded-cold-lookup state. Run it from the same ≥6 h maintenance hook (:704), guarded by an fsync-ordered receipt so a crash mid-replace leaves the original.
  1b. AtriaHistoricalArchiveDurableStore.swift:337 — persist `lastPruneAtUnix` (alongside the receipt state at `receiptStateURL`) instead of seeding it to `now()` in `init`, so relaunches cannot indefinitely postpone maintenance.
  1c. AtriaHistoricalLiveIdentityLookup.swift:89-105 — add `PRAGMA auto_vacuum=INCREMENTAL` at creation (needs a one-time rebuild for the existing DB, or add `PRAGMA incremental_vacuum(N)` after prune) and call a bounded `incremental_vacuum` from `prune(observedBefore:)` (:278) so freed pages actually return to the filesystem.
  1d. Consider shortening the key: `stableKey` (:86-98) embeds the full payload; a `strap|version|counter|unix|subsecond` prefix plus SHA-256 of the payload preserves exactness for rejection purposes at ~1/10 the bytes. This is a schema-v3 change — do it only behind a version bump, and only after 1a lands (1a alone bounds growth).

FIX 2 (unblock execution, honestly): Sessions.swift:25645-25648 — replace the constant `explicitDebugOverride` with a real, narrow authority. Do NOT just flip it to `true`: the comment at Sessions.swift:25918-25925 documents a genuine reason (composite readers are not all cooperatively cancellable). Instead split maintenance into two lanes and let only the safe one auto-run:
  - LANE A (safe, enable automatically): identity-index compaction (Fix 1) + `AtriaHistoricalGeneratedArtifactGC` + `AtriaHistoricalRetiredReplayIndex.maintainStorage` (already VACUUM-aware, HistoricalArchive.swift:9457-9470). These are bounded, per-file, and do not enter the whole-archive consumer graph. Give them their own `shouldExecuteBoundedStorageMaintenance(...)` returning the existing `shouldAdmitAutomaticArchiveCompaction` environmental decision (Sessions.swift:25617), so they run under the real BGProcessing lease.
  - LANE B (raw retirement): keep it fenced until the cooperative-cancellation proof exists, but make the fence a named, testable authority rather than a literal, e.g. `shouldExecuteArchiveWideMaintenance(explicitDebugOverride:coldConsumersReadable:)`.

FIX 3 (make raw prunable without losing insights): the derived tier is already rich enough (AtriaHistoricalAggregateChunk.swift:23-83) — the gap is that no READER can use it. Add a retired-chunk fallback so pruning is survivable:
  - HistoricalArchive.swift:7353-7372 — key the HR sidecar lookup on CATALOG CHUNKS, not on live raw URLs: iterate window-overlapping chunks from the catalog, accept `state == .retired` when a valid `hr-index-v1` sidecar binding exists, and only fall back to `rawScan` when the raw file is still present. Relax `validHeartRateSidecarBinding` (:7865-7871) to accept `.sealed || .retired`.
  - HistoricalArchive.swift:7602 — stop filtering `.retired` out of the candidate list unconditionally; instead return chunks tagged with whether their raw file exists, so readers can choose sidecar/aggregate vs raw.
  - Add an equivalent motion/gravity sidecar (or read `MotionEpoch` from aggregates-v2) before pruning anything the gravity reader (:8883) depends on.
  - Provenance must stay honest: reads served from the derived tier must be labeled derived (minute-resolution HR, epoch-resolution motion) — never presented as 1 Hz raw.

FIX 4 (unstick the aggregate tier): aggregates only materialize on the drain-terminal path (AtriaBLEManager.swift:38038). Add a bounded LANE-A driver that calls `HistoricalArchive.materializeNextSealedCatalogDependency` for N chunks per BG window regardless of drain terminal state, so sealed chunks get their aggregate + manifest promptly (227/686 today). This is the prerequisite that makes Fix 3 and any raw pruning actually eligible.

FIX 5 (user-visible honesty — Settings): AtriaSettingsView.swift:955-1030 — expand the Storage row into a real breakdown fed by `AtriaManagedStorageInventory.measure()` (which already produces exactly these categories, AtriaManagedStorageInventory.swift:44-75) instead of the four hand-picked subtotals it computes locally. Show: "Raw sensor history 2.99 GB · Insights 93 MB · Dedupe index 2.13 GB", plus one plain-language state line derived from the receipt's `retentionExecution`/`nextEligibleAction` fields — e.g. "Automatic cleanup is off in this build. Nothing has been deleted." Surface the same string that today only lands in the debug UserDefaults key. Add a "Free up space" action that runs LANE A on demand and reports the exact reclaimed byte count.

TIERING TARGET (once Fixes 1-4 land):
  - raw JSONL chunks: keep 14 days (the existing `AtriaHistoricalRetentionPolicy.production` horizon already matches the replay-dedupe horizon — do not shorten below it, replay correctness depends on it), hard ceiling 512 MiB. Retire only chunks with a committed aggregate + manifest + verified canonical replay artifact (the existing `AtriaHistoricalRawRetirementExecutor` proof chain, :99-230, is correct and should be left intact).
  - identity index + sqlite lookup: hard 14-day horizon, physically enforced (Fix 1). Target <100 MB steady state.
  - hr-index-v1 sidecars + aggregates-v2 + long-term rollups + sessions.json + stress-history: keep forever. That is ~110 MB for 5 weeks ≈ 1.2 GB/decade — acceptable, and it is what the user means by "insights persisted forever".
  - Steady-state projection at the user's ~81 MB/day raw ingest: 14 days raw ≈ 1.1 GB, which exceeds the 512 MiB cap — so either accept a documented ~1.2 GB ceiling or add compression (Fix 2 makes `AtriaHistoricalSealedJSONLCompression.commit` reachable; deflate on JSONL should give 4-6× ⇒ ~250 MB). Whichever is chosen, the number shown in Settings must be the number actually enforced.

DO NOT: prune raw before Fix 3 ships; delete aggregates-v2/retention-manifests-v2 (they are the ONLY proof that authorizes raw deletion); or shorten the 14-day identity horizon (AtriaHistoricalArchiveDurableStore.swift:16) — it is the replay-rejection boundary, not a storage knob.

**Test plan**

All XCTest, scheme AtriaTests, matching the repo's existing idioms (pure-unit + source-pin).

1. `AtriaHistoricalArchiveDurableStoreTests` (extends the existing prune suite at :1067-1169, which only ever exercises the fullyMaterialized lane — that is precisely why this shipped): add `testExpiredIdentitiesAreRemovedFromDiskWhenIndexExceedsEagerMaterializationBound`. Construct the store with `maximumEagerIdentityIndexBytes: 1` so `fullyMaterializedIdentityIndex == false`, append N identities at t0, advance the clock past `identityRetention`, call `pruneExpiredIdentities(now:)`, then assert (a) the on-disk `indexURL` byte count strictly DECREASED, (b) every retained line's `observedAtUnix >= cutoff`, (c) a fresh store opened on the same URL still rejects an in-horizon replay and accepts an expired one. This test fails on today's HEAD (the file size is unchanged) — it is the regression pin for the self-latch.

2. `AtriaHistoricalArchiveDurableStoreTests.testPruneCadenceSurvivesProcessRestart`: build a store, flush, deinit, rebuild with a `now` 7 h later, flush again, assert the prune ran — pins Fix 1b against the `lastPruneAtUnix = now()` reset at :337.

3. New `AtriaHistoricalLiveIdentityLookupTests.testPruneReclaimsPhysicalBytes`: insert ~50k entries, record file size, prune all, assert `attributesOfItem(.size)` decreased materially. Fails today (no auto_vacuum/VACUUM).

4. `AtriaHistoricalHighVolumeStoragePlannerTests.testCapRemainsBlockedWhenReplayEvidenceAloneExceedsCeiling`: pure-unit, feed a Snapshot with `replayEvidenceBytes = 1.29 GB` and fully-verified sealed chunks; assert `plan.state == .blocked` and `unresolvedNonActiveOverageBytes > 0`. Documents the device's real state and guards the fix that must shrink replay evidence, not raw.

5. `AtriaHistoricalRetentionConsumerCutoverTests` (extend): `testRetiredChunkHeartRateStillReadableFromSidecar` — build a sealed chunk, materialize its hr-index-v1 sidecar, retire it through `AtriaHistoricalRawRetirementExecutor`, then call `HistoricalArchive.exactMetricHeartRatePoints(in:catalog:archiveRoot:start:end:maximumPoints:)` over the retired window and assert the points are returned (and flagged derived). This is the safety gate for Fix 3 — it MUST be green before any pruning is enabled.

6. `AtriaBackgroundProjectionTests` source-pins at :2484 and :3023 assert the literal `guard Self.shouldExecuteArchiveWideMaintenance(` ordering, and :444-451 asserts the constant returns false for non-debug. Fix 2 must migrate those pins deliberately (split into a LANE-A pin asserting bounded maintenance IS admitted under the BG lease, and a LANE-B pin asserting whole-archive retirement still fails closed) rather than deleting them.

7. `AtriaManagedStorageInventoryTests` (exists per AtriaHandoff13Tests): add an assertion that the receipt's `retentionExecution` string is rendered into the Settings storage row, so the honest blocker cannot regress back into a debug-only UserDefaults key.

**Noticed nearby**

Four things worth flagging beyond the assignment:

1. THE BRIEF'S PREMISE IS WRONG ABOUT WHICH TIER THE USER READS. `aggregates-v2` (92.9 MB) is NOT the insight tier — it is retirement-proof machinery. Every `AtriaHistoricalAggregateReader` construction sits inside the retention/cutover graph (AtriaHistoricalRawRetirementExecutor.swift:99; HistoricalArchive.swift:1772, 1842, 2095, 2165, 2230, 2358, 2467, 2522); no UI or SessionStore path reads it. What the user actually reads is `sessions.json` (13.5 MB) + `daily-rollups.json` + `stress-history-v3`, and — for HR/motion charts — the RAW files themselves via `metricHeartRatePoints` / `loadGravitySamples`. That inverts the risk model: today the "insights" surface is coupled to raw, which is exactly why raw cannot yet be pruned, and it is the real work item behind Fix 3. The good news is the aggregate SCHEMA (AtriaHistoricalAggregateChunk.swift:23-83) already carries everything needed — it is just unwired to readers.

2. THE 4.35 MB / "32 MB" DISCREPANCY IS STALE METADATA, NOT A BUG. 2986.5 MB / 686 files = 4.35 MB, exactly `productionMaximumActiveBytes = 4 MiB` (AtriaHistoricalArchiveCatalog.swift:119). Rotation is healthy. The `rotationThresholdBytes=134217728` in `historical-archive.manifest.json` is the LEGACY daily-segment constant (HistoricalArchive.swift:34) still being written by `writeRotationManifest` (:7529) for a code path the catalog superseded — it will keep misleading every future forensic pull until it is removed or corrected.

3. `.gpx` ROUTE EXPORTS LEAK FOREVER. `AtriaGeneratedArtifactRetention` has policies for `atria-share-*.png`, `atria-workout-share-*.png`, `atria-export-*.zip`, `atria-capture-*.csv`, and `Atria-*.html` (AtriaGeneratedArtifactRetention.swift:36-59), pruned at AtriaApp.swift:63-74. But workout routes are written as `Atria-<workoutID>.gpx` (AtriaWorkoutRoute.swift:1543) and `portableWorkoutExports` allows extension `html` ONLY — so every shared GPX accumulates uncollected. One-line fix: add `gpx` to that policy's `allowedExtensions`, or give routes their own policy.

4. `atria-memprobe*.log` (part of the 17 MB of leftovers) has NO writer anywhere in the shipping Swift sources — the only textual hit is a comment at HistoricalArchive.swift:6483. Those files are almost certainly produced by an external dev/debug tool and are sitting in the user's Documents directory unmanaged and unpruned. Worth confirming they are not being written by a release build path before shipping a storage story.

**Challenger 1 — refuted=False**

I read every cited file:line. The three mechanisms are real and I could not break any of them.

(a) CONFIRMED VERBATIM. `Atria/Atria/Sessions.swift:25645-25648` is literally `nonisolated static func shouldExecuteArchiveWideMaintenance(explicitDebugOverride: Bool) -> Bool { explicitDebugOverride }` — no environmental input. `Sessions.swift:25904-25908` computes `explicitDebugOverride = reason == "debug_launch_arg" && ProcessInfo.processInfo.arguments.contains("--atria-compact-archive")`, and the guard at :25926 returns after `reserveArchiveCompactionForSafeBackground()` + `status=reserved_automatic_execution_disabled`. `AtriaApp.swift:886` passes the BG task's `reason`, and the lease minter `beginArchiveCompactionBGProcessingLeaseIfSafe` (:25686) hard-requires `reason == "bg_processing"` — so on the BG path the override is provably false. I tried to refute the "one entry point" claim for raw retention and could not: `compactArchive(olderThanDays:)` (HistoricalArchive.swift:9352), which contains every raw-retention site (retirement executor :9373, artifact GC :9407, replay-index maintainStorage :9465, shadow-compaction retention queue :9563/:9587), has exactly ONE caller — line 9860, inside `compactArchiveConverging`. So `AtriaHistoricalRetentionPolicy.production` (14d / 512 MiB, AtriaHistoricalRetentionPolicy.swift:9-12) genuinely never evaluates in a shipping build. Cold-session half also verbatim: `consumerReadiness: .shadowOnly, productionRawRetirementEnabled: false` (AtriaColdSessionMigration.swift:158-159), six `.unsupported(...)` (AtriaColdSessionStore.swift:39-46), `authorizesRawRetirement` requires all six `.available` (:62-65).

(b) CONFIRMED. `grep -rn "\.commit(chunkID" Atria/ | grep -v AtriaTests` returns ZERO hits. Every production reference to `AtriaHistoricalSealedJSONLCompression` is reader-side: `artifactExtension` skips (AtriaHistoricalJSONLRecentScanner.swift:19, Sessions.swift:14803), `Manifest` decode + `verifyCompressed` (AtriaHistoricalArchiveCatalog.swift:407-459, :726-744), and `TransactionError.tornTrailingRow` catches (AtriaHistoricalReplayIdentityShard.swift:256, AtriaHistoricalAggregateBuilder.swift:483). Rotation numbers also check out: `productionMaximumActiveBytes = 4 * 1024 * 1024` (catalog :119) with seal at `crossedDay || actualBytes >= maximumActiveBytes` (:261), and the 128 MiB `rotationThresholdBytes` (HistoricalArchive.swift:34) is stamped into `RotationManifest` at :7529-7534 for the legacy daily-segment path — the re

_Corrections:_ Claim stands; five corrections, two of which change the fix.

1. "`shouldAdmitAutomaticArchiveCompaction` … is dead code behind that fence" — WRONG, and wrong in a way that makes FIX 2 easier. It has two LIVE production references: Sessions.swift:25703 (inside `beginArchiveCompactionBGProcessingLeaseIfSafe`, UPSTREAM of the fence) and Sessions.swift:25875 (worker-admission recheck). It actually executes on device every BGProcessing wake: the full thermal/battery/background model runs, a 10-minute lease is minted (:25717-25723), and THEN `compactHistoricalArchiveIfUseful` throws it away at the fence. So it is unreachable-as-authority, not dead. Consequence for FIX 2: the environmental decision is already wired to a live BGProcessing lease with a cancellation token, so LANE A does not need new plumbing — `shouldExecuteBoundedStorageMaintenance(...)` can consume the lease that is already being minted and discarded today.

2. "The entire retention/compaction graph has exactly one production entry point" — OVERSTATED. It is true for RAW retention (verified: `compactArchive` has one caller). It is false for the generated-artifact GC lane: `AtriaHistoricalGeneratedArtifactGC(archiveRoot:).prune()` runs in production at AtriaHistoricalCanonicalConsumerDestinationStore.swift:524, inside `AtriaHistoricalCanonicalConsumerApplicationAdapter.apply`, called from `publishAndVerifyHistoricalConsumerCutover` (HistoricalArchive.swift:2701) ← `publishPendingConsumersUsingLatestFullScan` (HistoricalArchive.swift:2449) ← AtriaBLEManager.swift:38189 — the drain-terminal path, entirely outside the fence. Consequence for FIX 2: drop `AtriaHistoricalGeneratedArtifactGC` from the LANE-A "enable automatically" list — it is already automatic. LANE A's genuinely-new members are identity-index compaction (Fix 1) and `AtriaHistoricalRetiredReplayIndex.maintainStorage`. Note this GC lane is gated on the same stalled drain-terminal path, so it is currently starved at RUNTIME rather than fenced — wh

**Challenger 2 — refuted=False**

I re-derived this from the code and reached the same three-defect mechanism. All load-bearing claims check out; I found two additional defects they missed and one consequence they got backwards.

VERIFIED (a) — the release kill switch is real.
`SessionStore.shouldExecuteArchiveWideMaintenance(explicitDebugOverride:)` is literally `{ explicitDebugOverride }` (/Users/amanpandey/projects/atria/Atria/Atria/Sessions.swift:25645-25648). `compactHistoricalArchiveIfUseful` computes `explicitDebugOverride = reason == "debug_launch_arg" && ProcessInfo…arguments.contains("--atria-compact-archive")` (Sessions.swift:25914-25918) and bails at :25926 with `status=reserved_automatic_execution_disabled`. The only production caller is the BGProcessing handler at AtriaApp.swift:886, which passes `reason: "bg_processing"`. The launch-arg caller is Sessions.swift:51339-51340. `shouldAdmitAutomaticArchiveCompaction` (Sessions.swift:25617-25638) is dead code behind it.

I found a stronger confirmation than they cite: `AtriaHistoricalRetentionPolicy.production` (AtriaHistoricalRetentionPolicy.swift:9-12, 14 d / 512 MiB) has ZERO consumers anywhere except the default parameter of `AtriaHistoricalShadowCompactionCoordinator.retentionQueue(…policy:)` — and that function is called exactly once in the whole app, at HistoricalArchive.swift:9563, inside `compactArchive`. `compactArchive` (HistoricalArchive.swift:9352) is called exactly once, from `compactArchiveConverging` (:9860), itself called exactly once, from Sessions.swift:26024. It is a single unbranched chain behind one `guard`.

And it is not just raw retirement behind that fence. Every byte-reclaiming action in the archive tree lives inside `compactArchive`: the generated-artifact GC (HistoricalArchive.swift:9405-9412), the retired-replay `maintainStorage` VACUUM (:9462-9469, and the only `VACUUM` in the tree is AtriaHistoricalRetiredReplayIndex.swift:438), replay-payload compaction (:9428-9436), and `AtriaHistoricalRawRetirementExecutor.retire` (:9663) — the only file-unlink authority for a raw chunk. So on a user's phone nothing in `atria-historical/` has ever been deleted, at all.

Cold-session half of the blocker string also verified: `consumerReadiness: .shadowOnly, productionRawRetirementEnabled: false` hard-coded at AtriaColdSessionMigration.swift:157-158, six `.unsupported(...)` at AtriaColdSessionStore.swift:41-46, `authorizesRawRetirement` needs all six `.available` (:61-63, :78-80).

VERIFIED (b) — no compression pr

_Corrections:_ Mechanism confirmed — not refuted. Two additions they missed, one consequence they got backwards, one sharpening.

ADDITION 1 (new, and it changes the fix list): the 839.7 MB SQLite accelerator is INVISIBLE to both accounting authorities. Its path is built as `indexURL.deletingPathExtension().appendingPathExtension("lookup-v1.sqlite")` (AtriaHistoricalArchiveDurableStore.swift:1314-1315) = `historical-archive.identity.lookup-v1.sqlite`.
- `AtriaManagedStorageInventory.categoryPaths` lists only `…/historical-archive.jsonl` and `…/historical-archive.identity.jsonl` (AtriaManagedStorageInventory.swift:47-49), and `allocatedBytes` adds only `-wal`/`-shm` siblings of those exact paths (:124-131). The `.lookup-v1.sqlite` name matches nothing, so the "honest" per-launch storage receipt under-reports the container by ~840 MB (15%). The one artifact whose entire job is telling the truth about size is itself wrong.
- `AtriaHistoricalHighVolumeStorageAccounting.category(for:)` matches replay evidence by the exact filename `historical-archive.identity.jsonl`, its `.tmp` sibling, and the `retired-replay-v1/` prefix (AtriaHistoricalHighVolumeStoragePlanner.swift:215-246). The accelerator falls through to `.otherManaged`, and `highVolumeBytes = rawBytes + replayEvidenceBytes` excludes `.otherManaged` (:32-36). So 840 MB of live dedupe bookkeeping sits entirely outside the 512 MiB ceiling. The comment at :64-72 explicitly reasons about including the live replay index so the ceiling cannot undercount replay evidence — and then misses the file that mirrors it.

ADDITION 2 (precision on the latch): it is conditional, not unconditional. `shouldUseBoundedColdLookup = liveIdentityLookup != nil && existingIndexBytes > maximumEagerIdentityIndexBytes` (AtriaHistoricalArchiveDurableStore.swift:363-366). If the accelerator fails to open, the store falls to the eager path and `rebuildDerivedIndex` WOULD compact the file. So it is "latched for as long as the accelerator is healthy" — permanent 


---

### Item 8 and 9 — real-defect (refuted 1/2, confidence high)

**Root cause**

There are TWO independent, uncalibrated stress producers rendering onto the SAME 0–3 "Calm/Moderate/High" coordinate, and they share only the resting-HR reference — nothing else.

PRODUCER A (day / general / Vitals / Activity day-timeline) = `AtriaPhysiologicalStressModel.evaluate`, Atria/Atria/AtriaPhysiologicalStressModel.swift:312. Its HR term is a HEART-RATE-RESERVE coordinate: `let h = clamp01((meanHR - rest) / max(1, maximum - rest))` (line 363) then `let hrStress = sigmoid(8 * (h - 0.25))` (line 364), scaled `3 * motion.multiplier * base` (line 398) and EMA-smoothed (line 406). Denominator = HRmax − HRrest ≈ 132 bpm (age-30 default max 187, Insights.swift:576 `208 - 0.7*age`). Sigmoid center sits at 25% of reserve ≈ rest + 33 bpm.

PRODUCER B (the sleep detail) = `AtriaSleepStressProjection.make`, Atria/Atria/AtriaHealthScreen.swift:2569. Its whole activation is two lines:
  2598: `let threshold = max(10, Double(restingHeartRate) * 0.20)`
  2599: `let score = min(max((average - Double(restingHeartRate) - 3) / threshold, 0), 1) * 3`
Denominator = max(10, 0.2·rest) ≈ 11 bpm. It is a LINEAR ramp that HARD-SATURATES at 3.0 the moment a 5-minute mean exceeds rest + 3 + 11 ≈ rest + 14 bpm. No HRV, no motion attenuation, no EMA, no confidence, no hysteresis.

THE DIVERGENCE (rest = 55, max = 187, nocturnal 5-min mean = 69 bpm — an utterly ordinary REM/first-cycle overnight HR):
  Producer B → 3.00 → top bar, and the y-axis tick at 3 is literally rendered as the word "High" (AtriaHealthScreen.swift:2876 `Text(value == 3 ? "High" : "\(value)")`), plus an orange "N high periods · Xm" caption (2762) driven by `filter { $0.score >= 2 }` (2542).
  Producer A → 0.72 → "Calm" (Zone.resolve, AtriaPhysiologicalStressModel.swift:204: Calm <1, Moderate <2, High ≥2).
Same night, same minutes, same 0–3 axis, same resting reference, 4.2× apart. Producer B is ~12× more sensitive per bpm. That IS item 9.

This is not a labeling accident that stops at the sleep sheet: `AtriaActivityMonitor.refreshTimelineStress` (AtriaActivityMonitor.swift:2350-2391) deliberately extends the general stress trace over "the extended plot region (the anchoring sleep)" (comment at 2361), so the SAME night is simultaneously drawn Calm on the Activity day timeline and pinned High inside the sleep sheet.

ITEM 8 ("general reads too low") is the mirror image of the same calibration bug, and it is structural, not a tuning nit. `let weightHR = 0.5 + 0.5 * (1 - smoothstep(edge0: 0.05, edge1: 0.35, value: h))` (AtriaPhysiologicalStressModel.swift:365-367) drives weightHR → 1.0 as h → 0.05, so the HRV term's weight `(1 - weightHR)` (line 392) goes to ZERO exactly at sedentary heart rates — precisely where autonomic stress lives. Consequence: at HR 70 the maximum achievable score, even with maximally suppressed HRV (hrvStress = 1.0), is 0.86/3 → "Calm". The general surface is mathematically incapable of reporting anything above Calm while the user is sitting still, no matter how stressed. Getting to "High" (≥2) requires a sustained 5-min mean of ~100 bpm — an exercise threshold, not a stress threshold.

Contributing: the learned quiet-awake HR reference that the Aug-8 178k-sample recalibration produced is still computed and persisted every tick (AtriaStressMonitor.swift:3900-3921) but is then thrown away — `_ = awakeReference` at AtriaStressMonitor.swift:3922 and again at 379. The v3 rewrite replaced it with the fixed 25%-HRR center and never re-wired it, so the general score is scored against an exercise-intensity default rather than the user's own awake center.

NOT starved by the 4 h stall. Producer B reads the durable archive over the saved sleep window (`AtriaSleepStressArchiveProjection.load`, AtriaHealthScreen.swift:2662) and is deterministic given the HR rows, which exist (2986 MB of raw segments; drainedThrough 21:22). The 4 h silence explains items 1-3, not this.

**Evidence**

- Atria/Atria/AtriaPhysiologicalStressModel.swift:363 — PRODUCER A HR term denominator is heart-rate RESERVE: `let h = clamp01((meanHR - rest) / max(1, maximum - rest))`
- Atria/Atria/AtriaPhysiologicalStressModel.swift:364 — `let hrStress = sigmoid(8 * (h - 0.25))`; sigmoid center at 25% of reserve ≈ rest + 33 bpm
- Atria/Atria/AtriaPhysiologicalStressModel.swift:365-367 — `let weightHR = 0.5 + 0.5 * (1 - smoothstep(edge0: 0.05, edge1: 0.35, value: h))` → weightHR = 1.0 at rest, so the HRV term's weight is 0 at sedentary HR (item 8)
- Atria/Atria/AtriaPhysiologicalStressModel.swift:392 — `base = weightHR * hrStress + (1 - weightHR) * hrvStress`; the (1 - weightHR) factor is 0 at rest
- Atria/Atria/AtriaPhysiologicalStressModel.swift:398 — `let unsmoothed = clamp(3 * input.motionContext.multiplier * base, 0, 3)`; note sleepContext is carried at line 437 as PROVENANCE ONLY and never enters the score
- Atria/Atria/AtriaPhysiologicalStressModel.swift:204-208 — `Zone.resolve`: Calm <1, Moderate <2, High ≥2 (the general coordinate)
- Atria/Atria/AtriaHealthScreen.swift:2598 — PRODUCER B spread: `let threshold = max(10, Double(restingHeartRate) * 0.20)` (≈11 bpm vs Producer A's ≈132 bpm reserve)
- Atria/Atria/AtriaHealthScreen.swift:2599 — PRODUCER B score: `let score = min(max((average - Double(restingHeartRate) - 3) / threshold, 0), 1) * 3` — saturates at 3.0 for any mean ≥ rest+14
- Atria/Atria/AtriaHealthScreen.swift:2876 — the sleep card's y-axis tick at 3 renders the word "High": `Text(value == 3 ? "High" : "\(value)")`, orange at ≥2 (2878)
- Atria/Atria/AtriaHealthScreen.swift:2542 and 2762 — high periods are `filter { $0.score >= 2 }`, surfaced as an orange "N high periods · Xm" caption — the same ≥2 boundary the stress coordinate uses
- Atria/Atria/AtriaHealthScreen.swift:2852 — `.chartYScale(domain: mode == .load ? 0...3 : heartRateDomain)`: producer B is explicitly plotted on the 0–3 stress axis
- Atria/AtriaTests/AtriaSleepStressProjectionTests.swift:70-73 — the repo's OWN test pins the saturation: with rest 50, a flat 63 bpm night asserts score == 3.0, comment "resting + 3 + threshold saturates the 0–3 scale". Producer A on the same 63 bpm/rest 50 gives 0.67 → Calm.
- Atria/AtriaTests/AtriaSleepStressProjectionTests.swift:75-79 — 58 bpm asserts 1.5 (dead center of the scale) where Producer A gives ~0.51
- Atria/Atria/AtriaActivityMonitor.swift:5192 and Atria/Atria/AtriaHealthScreen.swift:1129 — the only two mount sites of `AtriaSleepStressCard`, i.e. producer B is the sleep-detail owner on both the Sleep sheet and the Health screen
- Atria/Atria/AtriaActivityMonitor.swift:1608 — the sleep sheet is fed `restingBaseline: store.baseline.restingInt`, the SAME learned resting EMA Producer A uses (AtriaStressMonitor.swift:3961 `restingHeartRate: baseline.restingHR ?? ...`) — proving the two share the reference but nothing else
- Atria/Atria/AtriaActivityMonitor.swift:2361-2391 — the general stress trace (`stressMonitorStore.history` → `evidenceProjection.numericStressScore`, producer A) is deliberately extended over "the anchoring sleep", so both traces cover the same night
- Atria/Atria/AtriaVitalsCollectionSections.swift:3767 — the general surface's own axis contract: "scale 0 through 3. Calm is 0 to 1, Moderate is 1 to 2, and High is 2 to 3"
- Atria/Atria/AtriaStressMonitor.swift:3900-3922 — the learned quiet-awake reference is computed, persisted and seeded, then discarded at line 3922 `_ = awakeReference` (also line 379 in the DEBUG adapter); the Aug-8 recalibration is dead code
- Atria/Atria/Insights.swift:576 and 580-584 — `ageEstimatedMaxHR = 208 - 0.7*age`, default age 30 → max 187, giving the ≈132 bpm reserve denominator
- No test anywhere cross-checks the two producers: the only test file naming both (Atria/AtriaTests/AtriaActivitySectionsCacheTests.swift:240 and :512) uses them for unrelated cache/availability assertions

**Proposed fix**

Two changes; the first is the real fix for item 9, the second for item 8.

FIX 1 (item 9 — one stress owner over the sleep window). Stop producing a second 0–3 series. In `AtriaSleepStressCard` (Atria/Atria/AtriaHealthScreen.swift:2702), the "HR load" mode must render Producer A's minute facts filtered to [sleepStart, sleepEnd] — the exact same source `AtriaActivityMonitor.refreshTimelineStress` already reads at Atria/Atria/AtriaActivityMonitor.swift:2365 (`stressMonitorStore.history` → `point.evidenceProjection.numericStressScore`). Concretely: add the history-derived samples to `AtriaSleepStressProjection` and delete the ad-hoc activation at AtriaHealthScreen.swift:2598-2599. When no v3 facts cover the night, the card must show an honest empty state (a new `.noStressFacts` case alongside `.insufficientWear` at AtriaHealthScreen.swift:2482-2486) rather than synthesizing a substitute — the HR trace mode (AtriaHealthScreen.swift:2733-2748) is already truthful and stays.

If FIX 1 is too large for this pass, the minimum bounded change is to get producer B OFF the stress coordinate entirely: (a) delete the "High" tick label at AtriaHealthScreen.swift:2876 and change `.chartYScale` at 2852 from `0...3` to a bpm-delta domain, plotting `average - restingHeartRate` in bpm; (b) re-band `highPeriods` (AtriaHealthScreen.swift:2542) on an absolute bpm delta, not a 0–3 score; (c) rename `AtriaSleepStressProjection`/`AtriaSleepStressCard`/`AtriaSleepStressArchiveProjection` → `AtriaOvernightHRLoad*` so the type names stop asserting a stress claim the disclaimer at AtriaHealthScreen.swift:2513 tries to walk back. Partial: it removes the contradiction but leaves the sleep detail with no real stress trace.

FIX 2 (item 8 — the general score cannot leave Calm at rest). At Atria/Atria/AtriaPhysiologicalStressModel.swift:365-367, cap the HR weight so the HRV term always carries real weight: `let weightHR = min(0.65, 0.5 + 0.5 * (1 - smoothstep(edge0: 0.05, edge1: 0.35, value: h)))`. Today weightHR reaches 1.0 at rest and zeroes the HRV term exactly where it is the only signal; a 0.65 cap gives HRV ≥35% at all heart rates while preserving the existing behavior above h≈0.2. Bump `AtriaPhysiologicalStressModel.scoringVersion` (line 11) from 3 to 4 so no build presents v3 and v4 points as one continuous series — `MinuteFact.isStructurallyValid` (line 249) and the shard schema already fail closed on a version mismatch. Separately, re-wire or delete the dead awake reference at AtriaStressMonitor.swift:3922 (`_ = awakeReference`): either feed its learned center into the sigmoid center in place of the fixed 0.25 HRR, or remove the whole learner (buffer, `AtriaAwakeBaselineArchive`, the throttled UserDefaults writes at 3894/3911) so it stops doing I/O for a value nothing reads. Re-centering is a product/calibration decision and should be validated against a device pull before shipping — do not guess a new constant.

**Test plan**

Add `AtriaStressProducerAgreementTests` to Atria/AtriaTests/, in the idiom of Atria/AtriaTests/AtriaSleepStressProjectionTests.swift (pure static calls, synthetic `HistoricalArchive.HeartRatePoint` strides, no I/O).

testBothStressProducersAgreeOnTheSameNight: build an 8 h flat 69 bpm night at 1-minute cadence with rest 55, max 187. Feed it to (a) `AtriaSleepStressProjection.make(points:sleepStart:sleepEnd:restingHeartRate: 55)` and (b) `AtriaPhysiologicalStressModel.evaluate([WindowInput])` framed at the same minute cadence with `Personalization(restingHeartRate: 55, maximumHeartRate: 187, restingBaselineDayCount: 30, hrvBaseline: nil)`. Assert the two mean 0–3 scores agree within 0.5 (one third of a band) and that they resolve to the SAME `AtriaPhysiologicalStressModel.Zone`. This FAILS at HEAD: 3.00 vs 0.72, High vs Calm. After FIX 1 it passes trivially because there is one producer.

testSedentaryStressCanLeaveCalmWhenHRVIsSuppressed (item 8): rest 55, max 187, constant 70 bpm, `hrvBaseline` with medianLnRMSSD well above a supplied current RMSSD so `hrvStress` ≈ 1.0. Assert `fact.score >= 1.0` (i.e. at least Moderate). FAILS at HEAD — the ceiling is 0.86 regardless of HRV — and passes with the weightHR cap.

testHighPeriodsAreNotDeclaredBelowTheStressHighBand: assert every `AtriaSleepStressProjection.highPeriods` timestamp corresponds to a Producer A fact whose `zone == .high`. Guards the regression permanently.

Also re-baseline `AtriaSleepStressProjectionTests.testConservativeActivationNeedsRealElevationAboveRestingHR` (lines 60-80) — its 63 bpm → 3.0 and 58 bpm → 1.5 assertions currently ENCODE the bug and must change with the fix. Run with the AtriaTests scheme (not Atria).

**Noticed nearby**

1. DEAD CALIBRATION STILL DOING I/O: the entire quiet-awake reference learner — 45-min ring buffer, `AtriaAwakeReferenceSnapshot` persistence throttled to every 5 min, and the multi-day `AtriaAwakeBaselineArchive` written every 20 samples (AtriaStressMonitor.swift:3880-3921) — runs on every live tick and its result is discarded one line later at AtriaStressMonitor.swift:3922 (`_ = awakeReference`). This is the Aug-8 "persist-reference + B3 + spread 12→14" work; the v3 rewrite orphaned it. It is burning UserDefaults writes for a value no shipping code reads.

2. INVERTED COLOR SEMANTICS on the sleep card: at AtriaHealthScreen.swift:2878 the y-tick colors are `value >= 2 ? .orange : (value == 1 ? .green : .blue)` — so on the sleep chart "1" is GREEN and "0" is BLUE, while the stress coordinate everywhere else treats 0–1 as the green calm band (AtriaVitalsCollectionSections.swift:3767). Even the color language disagrees between the two producers.

3. Producer B has NO smoothing, NO motion attenuation and NO confidence tier, so a single bathroom trip or one REM burst instantly paints a full 5-minute "high period" with an orange timestamp caption (AtriaHealthScreen.swift:2764-2771). Producer A would EMA-smooth the same excursion over a 3-minute half-life (AtriaPhysiologicalStressModel.swift:14, 406).

4. The night's own resting reference can be a MINIMUM, not a typical value: `restingHR: acceptedRestingHRs.min()` (Sessions.swift:18955) and `fallbackRHRs.min()` (Sessions.swift:20270). Whenever `restingBaseline` is nil and the sheet falls back to `night.restingHR` (AtriaActivityMonitor.swift:5122), producer B compares 5-minute MEANS against the night's FLOOR, which pushes it even harder into saturation.

5. `SleepContext` is threaded all the way into `MinuteFact` (AtriaPhysiologicalStressModel.swift:437, and qualified at AtriaStressMonitor.swift:2274) but never touches the score — the v3 model has no sleep-specific calibration at all. That is defensible for a reserve-based model, but it means neither producer has an actual sleep-appropriate reference; one ignores sleep and the other over-reacts to it.

6. Unrelated to 8/9 but visible while reading: `AtriaStressHistoryArchive.retentionWindow = 48 * 60 * 60` (AtriaStressMonitor.swift:695) means the general stress trace is only retained 2 days, which is why the sleep detail (which re-reads the durable HR archive) is the only thing that can render an older night at all — directly relevant to item 12's "insights persisted forever" ask, and it is also why FIX 1 needs the honest `.noStressFacts` empty state rather than silently falling back.

**Challenger 1 — refuted=True**

Every quoted line is verbatim-accurate and the arithmetic checks out — but the load-bearing premise ("two producers rendering onto the SAME 0–3 Calm/Moderate/High STRESS coordinate") is false as shipped, and the mitigation the claim proposes as its own fallback fix has already landed.

WHAT I CONFIRMED (all verbatim at the cited lines):
- Producer A: 363 `let h = clamp01((meanHR - rest) / max(1, maximum - rest))`, 364 `sigmoid(8 * (h - 0.25))`, 365-367 the weightHR smoothstep, 392 `base = weightHR * hrStress + (1 - weightHR) * hrvStress`, 398 the `3 * multiplier * base` clamp. Zone.resolve Calm/Moderate/High at 204-208.
- Producer B: 2598-2599 exactly as quoted. Saturation at rest+14 confirmed; score>=2 (the "high period" band) begins at rest + 10.33 bpm.
- Tests AtriaSleepStressProjectionTests.swift:68-79 pin 3.0 at 63bpm/rest50 and 1.5 at 58bpm exactly as claimed.
- Motion multiplier (AtriaPhysiologicalStressModel.swift:128-131) is `max(0.65, 1 - 0.35*intensity)`, i.e. ALWAYS <= 1, so item 8's ceiling really is a hard ceiling. My recompute at rest 55 / HR 70: weightHR = 0.954, HRV weight 0.046, max achievable score 0.88 -> Calm. Confirmed. At h <= 0.05 (HR <= rest+6.6) the HRV weight is exactly ZERO.
- Divergence arithmetic at rest 55 / mean 69: Producer B = 3.00, Producer A (HR-only) = 0.72. Confirmed.
- Dead learner CONFIRMED: `_ = awakeReference` at AtriaStressMonitor.swift:3922 and :379, while `awakeBaselineArchive.record`/`.save` (3891-3896) and `persistAwakeReference` (3912) still do throttled UserDefaults I/O for a value nothing reads. This is the one finding I would ship unmodified.
- refreshTimelineStress does extend over the anchoring sleep (comment at 2361, interval at 2362).
- No cross-producer test exists.

WHY THE CLAIM IS REFUTED:

1. Producer B is NOT on the stress coordinate — the rename the claim proposes as its own fallback is already shipped. I dumped every literal `Text("...")` the card renders (AtriaHealthScreen.swift:2702-2960). The word "stress" appears ZERO times in any user-visible string. It appears only in Swift identifiers and code comments. What renders is: title "Overnight HR load" (2779); mode selector "Heart rate" / "HR load" (2712); chart y-values `.value("Load", ...)` (2801/2808); availability strings "Overnight HR load unavailable", "Building overnight HR baseline", "Not enough overnight wear" (2500-2502); and the footer at 2513 verbatim: "Atria's 0–3 heart-rate-load scale, relative to your resting heart rate. It is no

_Corrections:_ CORRECTED ITEM 9 (downgrade from "two stress producers on one coordinate" to "the HR-load band reuses stress vocabulary and fires too readily"):
The sleep card is already a separately named, separately disclaimed metric ("Overnight HR load", "It is not stress, a sleep stage, or a diagnosis"). The residual defect is two-fold and bounded:
(a) The tick at 3 renders the word "High" (AtriaHealthScreen.swift:2876) and the caption renders "N high periods · Xm" in orange (2762) — importing the general surface's top-zone vocabulary onto a scale that explicitly disclaims being that scale.
(b) The `>= 2` band (2542) fires at rest + 10.33 bpm. Nocturnal REM routinely exceeds resting + 10, so an ordinary night will show an alarm-orange "N high periods" caption. That is a calibration problem in the HR-load band itself, independent of Producer A.
Correct minimal fix: relabel the tick at 2876 from "High" to "3" (or to a bpm-delta), and re-band `highPeriods` on a defensible bpm delta rather than the reused 0–3 score. Optionally rename the three internal `*Stress*` types to `AtriaOvernightHRLoad*` for code hygiene — no user-visible change. Do NOT replace Producer B with Producer A: the 48 h `retentionWindow` (AtriaStressMonitor.swift:695) makes Producer A unable to cover historical nights, so FIX 1 trades a working trace for a permanent empty state on most sleep sheets.

CORRECTED ITEM 8 (mechanism confirmed, proposed constant rejected):
Confirmed: at h <= 0.05 the HRV term's weight is exactly zero, and at HR 70 / rest 55 the score ceiling is ~0.88 -> always "Calm". This is real and structural. But it is a deliberate, test-pinned design (AtriaPhysiologicalStressModelTests.swift:22), so any change is a calibration decision, not a bug fix. Do not ship the guessed 0.65 cap: it breaks the pinned test, is exactly the kind of guessed constant the claim itself forbids, and would let HRV alone push the general surface — which really does print Calm/Moderate/High — into Moderate/High against 

**Challenger 2 — refuted=False**

I re-derived this from source without relying on their write-up, and every load-bearing claim checks out. Confirmed by reading:

PRODUCER A (day/general/Vitals/Activity day-timeline) = `AtriaPhysiologicalStressModel.evaluate`, Atria/Atria/AtriaPhysiologicalStressModel.swift:312. Verified verbatim: line 363 `let h = clamp01((meanHR - rest) / max(1, maximum - rest))`, line 364 `let hrStress = sigmoid(8 * (h - 0.25))`, lines 365-367 `let weightHR = 0.5 + 0.5 * (1 - smoothstep(edge0: 0.05, edge1: 0.35, value: h))`, line 392 `base = weightHR * hrStress + (1 - weightHR) * hrvStress`, line 398 `let unsmoothed = clamp(3 * input.motionContext.multiplier * base, 0, 3)`, line 406 EMA. Bands at line 204 `Zone.resolve`: Calm <1, Moderate <2, High >=2. Age-estimated max at Insights.swift:576 `Int((208.0 - 0.7 * Double(age)).rounded())`.

PRODUCER B (sleep detail) = `AtriaSleepStressProjection.make`, Atria/Atria/AtriaHealthScreen.swift:2569. Verified verbatim at 2598/2599: `let threshold = max(10, Double(restingHeartRate) * 0.20)` / `let score = min(max((average - Double(restingHeartRate) - 3) / threshold, 0), 1) * 3`. No HRV, no motion, no EMA, no confidence. Mounted at AtriaActivityMonitor.swift:5192 (sleep review sheet) and AtriaHealthScreen.swift:1129.

SHARED REFERENCE — confirmed. Producer A: `restingHeartRate: baseline.restingHR ?? Double(restingMaxHR.rest)` (AtriaStressMonitor.swift:3958-3963). Producer B: `restingBaseline: store.baseline.restingInt` (AtriaActivityMonitor.swift:1608) and `vitalsStore.state.baseline.restingInt` (AtriaHealthScreen.swift:1004). Same `PersonalBaseline.restingHR`, one rounded (Insights.swift:203). So the prompt's stated hypothesis ("sleep surface computes against the AWAKE reference") is wrong; their finding that the reference is shared is right.

SAME COORDINATE — confirmed geometrically, not just conceptually. Producer B renders `chartYScale(domain: 0...3)` (AtriaHealthScreen.swift:2852) with the tick at 3 literally labeled `Text(value == 3 ? "High" : "\(value)")` (2876), orange markers on `score >= 2` (2816), high periods from `filter { $0.score >= 2 }` (2542, 2565), orange caption (2759/2789). The general chart uses the identical 0...3 domain with Calm/Moderate/High band rectangles at yStart 0/1/2 (AtriaVitalsCollectionSections.swift:4155, 4160, 4165) — and paints an explicit indigo *asleep* overlay across the same night (4176-4187, `yEnd: "Sleep ceiling", 3`). Plus AtriaActivityMonitor.swift:2350-2391 extends the general trace ac

_Corrections:_ Mechanism upheld. Five corrections/deepenings:

1. THE REFERENCE IS SLEEP-BIASED, WHICH MAKES B WORSE THAN "MISCALIBRATED" — IT IS SATURATED BY DESIGN.
`PersonalBaseline.restingHR` is not an awake center. `canonicalDailySamples` (Insights.swift:239-259) keeps one sample per day, prefers `isOvernightSample` (confirmed main sleep), and within a class keeps the LOWEST `restingHR`; `learn(...)` comments this at Insights.swift:137-140. So the shared reference is an EMA of the per-day sleeping near-minimum. Producer B then puts full scale 11 bpm above that minimum (+3 dead zone). Every physiologically normal REM/arousal excursion is 15-25 bpm above sleeping minimum, so score pins at 3.0 for a large fraction of EVERY healthy night. It is not "12x more sensitive" — measured slope is 3/11 = 0.273/bpm vs Producer A's 3*8*sigma(1-sigma)/132 = 0.033/bpm at h~0.11, so ~8x — but the real defect is that it has near-zero discriminative power: it is effectively a binary "HR > sleeping min + 14" indicator plotted on a Calm->High axis. "A lot of the time it is at 3" is the expected output for a healthy night, not an anomaly.

2. THE DEFECT IS PINNED BY A UNIT TEST — any fix must migrate a baseline.
Atria/AtriaTests/AtriaSleepStressProjectionTests.swift:56-80 `testConservativeActivationNeedsRealElevationAboveRestingHR` asserts rest 50 + HR 63 -> 3.0 with the comment "resting + 3 + threshold saturates the 0-3 scale", and rest 50 + HR 58 -> 1.5. The saturation is codified as intended behavior. They did not surface this.

3. THE EXISTING MITIGATION IS LEXICAL AND GIVES FALSE ASSURANCE.
Someone already noticed this collision and "fixed" it by renaming: the card title is "Overnight HR load" (AtriaHealthScreen.swift:2777) and the ready-state copy says "It is not stress, a sleep stage, or a diagnosis" (2515). That is enforced by AtriaSleepStressProjectionTests.swift:145 `testNoUserFacingCopyCallsTheHROnlyResultStress`, which regex-greps every app .swift for the literal string "sleep stress". 


---


## REFUTED — do not act on these as written

### Item 13 — feature-gap (refuted 2/2, confidence high)

**Root cause**

Atria has six "learning" engines, but every one of them is keyed on the two inputs this user's data cannot produce — a per-day `recoveryPercent` and manually-tagged journal days — while the one input he has in abundance (5 weeks / 227 files of aggregates-v2 heart-rate + RR sufficient statistics) is never read for insight at all. Concretely: `AtriaBehaviorImpact.summariesCancellable` builds `recoveryByDay` from `AtriaBehaviorImpact.Day.recoveryPercent` and returns `[]` when that map is empty (AtriaBehaviorImpact.swift:63-73), then gates on >=5 logged + >=5 comparison days inside a 90-day window (AtriaBehaviorImpact.swift:27-31); the v2 engine adds the same shape with stricter gates (AtriaJournalInsights.swift:105-113); `AtriaHighlights` is exactly two hardcoded rules over `DailyRollupStoreEntry` (AtriaHighlights.swift:20-23); `healthDeviationDecision` needs `DailyRollupVitals.Stat.n >= 3` on RHR/HRV/resp (LocalNotificationScheduler.swift:1336-1348); `MonthlyReport` needs 14 days (AtriaMonthlyReport.swift:15); and the whiteboard coach sentence hides its number entirely until 14 trusted baseline nights (Dashboard.swift:336-344, PersonalBaseline.trustedMinimumSamples = 14 at Insights.swift:26). The "AI coach" is not a learning engine at all: it defaults to `.off` (AtriaAICoach.swift:31), local mode is one template sentence restating today's numbers (AtriaAICoach.swift:380-397), and cloud mode is hard-disabled and only renders a request preview (AtriaAICoach.swift:405-422). The single aggregate->product path that exists computes canonical strain and requires `metric.missingMinuteCount == 0` (Sessions.swift:19779-19783), a whole-day-coverage gate a user with a chronic backlog never clears. So the app is not lying to him and nothing is broken — there is simply no engine that turns accumulated measurement into a suggestion, and the ones that exist starve on inputs he does not have. This is NOT the 4 h stall: the stall explains today's blank numbers, but `hrv.lastReadyAnalysisAt` has been stuck since 2026-08-11 (8 days) and the gap is structural.

**Evidence**

- Atria/Atria/AtriaAICoach.swift:31 — `var mode: Mode = .off`: the coach card ships inert unless the user opts in
- Atria/Atria/AtriaAICoach.swift:380-397 — AtriaLocalCoachProvider.answer: a single interpolated sentence of today's strain/recovery/HRV/stress; no history, no learning
- Atria/Atria/AtriaAICoach.swift:405-422 — AtriaCloudCoachProvider.answer: returns a request PREVIEW, 'Network requests stay disabled until a reviewed provider client is added'
- Atria/Atria/AtriaAICoach.swift:304-310 — fabricationFlags(response:payload:): existing post-hoc numeric audit primitive worth reusing for any generated copy
- Atria/Atria/Dashboard.swift:146-311 — enum Coach: recovery -> 9..17 strain target + push/hold/rest guidance (a rule, not a learner)
- Atria/Atria/Dashboard.swift:336-344 — AtriaWhiteboardCoachSentence falls to 'Calibrating your baseline — N of 14 nights' and returns target: nil
- Atria/Atria/AtriaMetricTargets.swift:173-188 — AtriaBaselineTargetSnapshot.hrvBandZ/restingBandZ: the single personal-band z authority, returns nil (never 0) when untrusted
- Atria/Atria/AtriaTodayScreen.swift:4107-4212 — AtriaTodayMorningWhiteboardModel.make: HRV/RHR/sleep/yesterday rows with band text + 'calibrating · N of 14 nights' fallback
- Atria/Atria/AtriaBehaviorImpact.swift:27-31 — gates: trailingWindowDays 90, minimumLoggedDays 5, minimumComparisonDays 5, minimumImpact 3.0, maximumPValue 0.10
- Atria/Atria/AtriaBehaviorImpact.swift:63-73 — recoveryByDay built solely from Day.recoveryPercent; empty map => returns []
- Atria/Atria/AtriaJournalInsights.swift:104-113 — insight-engine v2 gates (minimumSideDays 5, minimumSplitTotalDays 12, minimumCorrelationPairs 8, minimumAbsRho 0.3, permutationCount 2000)
- Atria/Atria/AtriaJournalInsights.swift:19-51 — JournalInsight.valueText/confidenceText already carry n and a high/moderate confidence word: the exact honesty grammar to reuse
- Atria/Atria/AtriaHighlights.swift:20-55 — the whole highlight engine is two rules: 2-night sleep-need streak, RHR >=2 below the 7-day mean
- Atria/Atria/Sessions.swift:4088-4116 — struct AtriaInsight (tag -> recovery/hrv/rhr delta, days)
- Atria/Atria/AtriaOverviewSections.swift:15053-15119 — AtriaInsightsCardHost/AtriaInsightsCard: 'Tag your days … and Atria learns what moves your HRV'
- Atria/Atria/AtriaTodayScreen.swift:425-431 — that Insights card is only reachable inside the `showInsights` sheet, not in the Today stack
- Atria/Atria/LocalNotificationScheduler.swift:1326-1367 — healthDeviationDecision: two-day |z|>=2 over RHR/HRV/resp, requires DailyRollupVitals.Stat n>=3, body 'has been above/below your typical range for 2 days'
- Atria/Atria/AtriaNotificationCategories.swift:23,49,98-100 — .healthDeviation category, kind 'health_deviation', honest description already promises exactly this two-day claim
- Atria/Atria/AtriaAssistantScreen.swift:50-56 — five deterministic prompt chips; every answer fails closed (e.g. behaviorsAnswer at :224-234 says 'a behavior needs 5+ logged days')
- Atria/Atria/AtriaMonthlyReport.swift:15,55-75 — minimumDaysForStats 14; below it every stat is nil and isBuilding is true
- Atria/Atria/AtriaMaxHRSuggestion.swift:16-44 — AtriaMaxHRSuggestionEngine: the one existing observe->propose->dismiss loop (lookback 180d, p95, triggerDelta 3, suppressDays 60) — the template for a suggestion contract
- Atria/Atria/AtriaHistoricalAggregateChunk.swift:23-41 — HeartRateMinute: minuteStart, samplesByBPM, terminalBPMSeconds, transitionHalfBPMSeconds, coveredSeconds, droppedGapSeconds
- Atria/Atria/AtriaHistoricalAggregateChunk.swift:43-62 — RREpoch: exact NN sufficient statistics (sumNN, sumNN^2, adjacent-diff sums, pNN50 count) + coverage and maxGap
- Atria/Atria/AtriaHistoricalAggregateReader.swift:104 — load(since:until:limits:) applies date bounds from the small manifest before any aggregate is hashed/decoded (memory scales with lookback)
- Atria/Atria/AtriaHistoricalAggregateReader.swift:749-786 — rrStatisticsForCompleteEpochs: exact epoch composition incl. adjacent-epoch bridging; 'partial-window reanalysis after raw expiry is intentionally unsupported'
- Atria/Atria/AtriaHistoricalDailyConsumerProjection.swift:132-142 — DailyMetric already carries heartRateState + representedMinuteCount + missingMinuteCount per civil day
- Atria/Atria/Sessions.swift:19779-19783 — canonical strain requires `metric.missingMinuteCount == 0`, so aggregate-derived value is suppressed for any gappy day
- Atria/Atria/AtriaHistoricalLongTermRollup.swift:9-13,109-115 — a complete per-UTC-day HR/RR/motion facts model with validate(); grep shows it is referenced ONLY by itself and Atria/AtriaTests/AtriaHistoricalLongTermRollupTests.swift (dead in production)
- Atria/Atria/AtriaRelativeSkinNightStore.swift:47-80 — AtriaRelativeSkinStoredNight + compact atomic versioned store keyed by identity+algorithm version, carrying receiptDrainedThroughUnix as the durability proof
- Atria/Atria/AtriaRelativeSkinNightStore.swift:363-370 — AtriaRelativeSkinSignalCenter.shared.install(_:) MainActor publish idiom
- Atria/Atria/Sessions.swift:14148-14180 — the off-main producer -> atomic store -> MainActor install pattern, guarded by ticket/authority/revision rechecks
- Atria/Atria/Sessions.swift:22817-22910 — recomputeBehaviorInsights: utility-queue pure compute + generation/revision-gated main-thread publish (the wiring template)
- Atria/Atria/Sessions.swift:9560-9567 — the @Published derived-cache block where a new suggestions cache belongs
- Atria/Atria/Insights.swift:26 — PersonalBaseline.trustedMinimumSamples = 14; :27 staleAfter = 21 days
- Atria/Atria/AtriaMetricConfidencePresentation.swift:23-53 — AtriaMetricConfidenceLevel (.high/.moderate/.limited/.provisional) with fixed short labels: the confidence vocabulary any new engine must speak
- device-defaults: hrv.lastReadyAnalysisAt = 2026-08-11 (8 days) vs hrv.lastNormalWearAnalysisAttemptAt = 2026-08-15 — HRV/RR path starved long before the 4 h stall
- device-container: Documents/atria-historical/aggregates-v2 = 92.9 MB / 227 files spanning 2026-07-12..08-18 — the substrate the proposed engine reads
- device-defaults: offlineSync.rangeLossBackfillPending = true, requested 2026-08-06; offlineSync.lastDrainFailure.v1 protocolViolation(history_sequence_gap_replay_mismatch) 2026-08-18 02:08 — the measurable coverage holes the engine must name rather than hide

**Proposed fix**

Add ONE engine — the "quiet-heart-rate band" — that derives from aggregates-v2, persists a ~1 KB/day durable profile, and emits typed, evidence-carrying suggestions. It needs no motion, no recovery score, and no journal, so it works on exactly this user's HR-only + motion-backlogged data.

NEW FILE 1 — Atria/Atria/AtriaAggregateDayProfile.swift (pure, Codable, Sendable):
  `struct AtriaAggregateDayProfile` { localDay, dayStart, dayEnd, timeZoneIdentifier; hourBuckets: [Hour(hourIndex, sampleCount, sumBPM, minimumBPM, maximumBPM, coveredSeconds, droppedGapSeconds)]; quietHR: QuietWindow?; rrNight: RRNightFacts?; coverage: Coverage(capturedMinutes, nightCapturedMinutes, nightSpanMinutes); provenance(sourceChunkIDs, aggregateContentSHA256s, algorithmVersion "aggregate-day-profile-v1", drainedThroughUnix, settled: Bool) }.
  `enum AtriaAggregateDayProfileBuilder { static func build(snapshot: AtriaHistoricalAggregateReader.Snapshot, since:until:timeZone:drainedThroughUnix:) -> [AtriaAggregateDayProfile] }` — folds AtriaHistoricalAggregateChunk.HeartRateMinute (AtriaHistoricalAggregateChunk.swift:23-41) into local-hour buckets, deliberately DROPPING samplesByBPM so a day is ~1 KB (365 KB/year, prune-proof). quietHR = lowest-mean contiguous 30-minute window inside the local 22:00-10:00 span, emitted ONLY when >=25 of 30 minutes each have >=45 coveredSeconds; otherwise nil (never a partial-coverage number). rrNight folded only from RREpochs wholly inside the night span, reusing the exact composition rule at AtriaHistoricalAggregateReader.swift:749-786. A day whose dayEnd > drainedThroughUnix is stored `settled: false` and is rebuilt on the next pass — same durability-receipt discipline as AtriaRelativeSkinStoredNight.receiptDrainedThroughUnix (AtriaRelativeSkinNightStore.swift:47-52).

NEW FILE 2 — Atria/Atria/AtriaAggregateDayProfileStore.swift: a line-for-line copy of the store idiom at AtriaRelativeSkinNightStore.swift:57-80 (versioned envelope, atomic replace, fail-closed load, NSLock), writing Documents/atria-insights-v1/day-profiles-v1.json. This is the "insights persisted forever" tier the user asked for in item 12 and it survives raw AND aggregate pruning.

NEW FILE 3 — Atria/Atria/AtriaQuietHeartRateBand.swift (pure): `struct AtriaQuietHeartRateBand { mean, sd, nights, windowDays }`; band is `trusted` at >=14 qualified nights in 30 (matching Insights.swift:26), `provisional` at 7-13 (shown but labelled), absent below 7. `func z(quietHR:) -> Double?` returns nil when untrusted or sd degenerate — the same nil-not-zero rule as AtriaMetricTargets.swift:177-187.

NEW FILE 4 — Atria/Atria/AtriaSuggestionEngine.swift (pure ranking + wording): `struct AtriaSuggestion { id, kind(.observation/.blocked/.action), headline, detail, evidence, confidence: AtriaMetricConfidenceLevel, route: AtriaMetricDetailKind?, dismissal }` reusing AtriaMetricConfidenceLevel (AtriaMetricConfidencePresentation.swift:23-53) and the dismissal contract of AtriaMaxHRSuggestionEngine.Dismissal (AtriaMaxHRSuggestion.swift:23-26,37-42). `static func suggestions(profiles:band:journalDayCount:syncFrontier:backfillRequestedAt:now:) -> [AtriaSuggestion]` with exactly four v1 rules: (1) quiet_hr_band observation, >=7 nights; (2) quiet_hr_deviation action, |z|>=1.5 on two consecutive nights with a TRUSTED band only — the same two-day shape already shipped at LocalNotificationScheduler.swift:1350-1355; (3) evidence_blocked, emitted whenever recent days have nightCapturedMinutes/nightSpanMinutes < 0.5, naming the count and newest gap; (4) journal_leverage, only when profiles.count >= 10 && journalDayCount < AtriaBehaviorImpact.minimumLoggedDays (referencing the constant at AtriaBehaviorImpact.swift:29, not a literal). Invariant enforced by test: no AtriaSuggestion may be constructed with an empty `evidence` string, and every evidence string contains an n.

EDITS (anchors):
- Sessions.swift:9562 (beside `behaviorInsights`) — add `@Published private(set) var aggregateSuggestions: [AtriaSuggestion] = []` + a revision counter.
- Sessions.swift:22817 — add `recomputeAggregateSuggestions(executionShouldContinue:completion:)` cloning the recomputeBehaviorInsights shape: utility queue, window-load ONLY the missing day range via AtriaHistoricalAggregateReader.load(since:until:limits:) (AtriaHistoricalAggregateReader.swift:104), build + replaceAll into the store, compute suggestions, publish on main behind the same generation/revision guard used at Sessions.swift:22898-22905.
- Sessions.swift:14148 — call it inside the existing off-main recovered-data authority window, immediately after the relative-skin producer block, so it inherits ticket/authority rechecks and never opens a new background lane.
- AtriaOverviewSections.swift:15053 — add `AtriaSuggestionsCardHost` beside AtriaInsightsCardHost.
- AtriaTodayScreen.swift:352-357 — place the new card inline under the morning whiteboard. Do NOT bury it in the `showInsights` sheet (AtriaTodayScreen.swift:425-431) where today's insights card is invisible.
- LocalNotificationScheduler.swift:1336-1341 — append quiet-HR as a fourth candidate in `healthDeviationDecision` so delivery reuses the existing `.healthDeviation` category (AtriaNotificationCategories.swift:23) and its already-honest description ("When a vital runs outside your typical range for 2 days") — no new toggle, no new user-facing promise.

DO NOT: extend AtriaHistoricalDailyConsumerProjection or add a MaterializedProjection.Kind — that bumps dailyMetricsAlgorithmVersion/configurationSHA256 and invalidates every published consumer receipt. The new store is deliberately outside the sealed archive contract.

WHAT IT WOULD SAY TO THIS USER TODAY (all four lines derivable from his actual device state):
1. "Quiet overnight heart rate: typically 4X-5X bpm across 12 of the last 30 nights (provisional — 14 nights makes it your band)." — buildable now from the 227 aggregates-v2 files spanning 07-12..08-18, while the whiteboard still says "calibrating" because hrv.lastReadyAnalysisAt has been stuck since 08-11.
2. "Last night isn't scored. Only ~1 h of the 22:00-10:00 window was captured — heart rate went silent at 21:56 and about 4 h are missing." (last HR sample 2026-08-18 21:56:32, watchdog.lastRawGap 14474.9 s)
3. "6 nights between 6 Aug and 18 Aug have less than half the night captured. A backfill has been pending since 6 Aug; those nights will score once it finishes." (rangeLossBackfillPending, requested 2026-08-06; drain failure 08-18 02:08)
4. "Atria has 30 nights of measured heart rate and 0 tagged days. Tag 5 days and the impact engine can start testing what moves your recovery." (AtriaBehaviorImpact.minimumLoggedDays = 5)
It says NOTHING about sleep stages, naps, steps, or stress — motion is backlogged, so those rules simply do not fire. Degradation removes rules; it never softens a claim.

**Test plan**

Pure XCTest, scheme AtriaTests, temp-directory + fixture chunks following Atria/AtriaTests/AtriaHistoricalLongTermRollupTests.swift (temp dir at :372) and AtriaBehaviorImpactPresentationTests.swift. No UserDefaults writes (suites share process/defaults). Two new files:

Atria/AtriaTests/AtriaAggregateDayProfileTests.swift
1. testHROnlyNightStillYieldsQuietWindow — build from fixture chunks containing HeartRateMinute rows and ZERO MotionEpoch rows; assert quietHR != nil. Proves the engine survives this user's HR-only reality (the exact condition that fails sleep stages today).
2. testUnderCoveredNightYieldsNilQuietHRAndABlockedSuggestion — 24 of 30 minutes covered; assert quietHR == nil AND the engine emits a .blocked suggestion whose detail names the missing minutes; assert no numeric bpm appears in that suggestion.
3. testProvisionalDayIsRebuiltAndSettledDayIsByteIdentical — a profile whose dayEnd > drainedThroughUnix stores settled:false and is replaced when the frontier advances; a settled day re-encodes byte-identically on rebuild (mirrors the parity discipline of AtriaHistoricalLongTermRollup.validate()).
4. testRRNightFactsUseOnlyCompleteEpochs — an epoch straddling the night boundary is excluded; adjacent complete epochs bridge exactly, matching AtriaHistoricalAggregateReader.rrStatisticsForCompleteEpochs (AtriaHistoricalAggregateReader.swift:749-786).

Atria/AtriaTests/AtriaSuggestionEngineTests.swift
5. testBandSampleSizeIsAlwaysDisclosed — 6 nights => no band suggestion; 7 => text contains "7 nights" and confidence == .provisional; 14 => confidence == .moderate/.high and text contains "14 nights". Pins the sample-size disclosure to the rendered string.
6. testDeviationRequiresTrustedBandAndTwoConsecutiveNights — z = -1.8 on two consecutive nights with a trusted band => exactly one .action suggestion; identical input with a provisional band => zero. Locks the fail-closed rule.
7. testJournalLeverageRuleIsPinnedToTheGateConstant — asserts the rule fires iff journalDayCount < AtriaBehaviorImpact.minimumLoggedDays, referencing the constant so copy can never drift from the gate.
8. testEverySuggestionCarriesEvidenceWithAnN — property test over all four rules: `evidence` is non-empty and contains a digit. This is the honesty invariant.

**Noticed nearby**

(1) Atria/Atria/AtriaHistoricalLongTermRollup.swift is 1026 lines of fully-validated per-UTC-day HR/RR/motion facts (validate() at :151-247) and is referenced by NOTHING in the app — grep over Atria/ finds only the file itself and Atria/AtriaTests/AtriaHistoricalLongTermRollupTests.swift. A complete "insights persisted forever" tier already exists as dead code; item 12's retention design should probably adopt it rather than invent a new one. (2) The Insights card is only reachable from a modal sheet (AtriaTodayScreen.swift:425-431, `showInsights`), so even when a behavior insight does clear its statistical gate the user may never see it. (3) The "AI coach" ships inert twice over: mode defaults to .off (AtriaAICoach.swift:31) and cloud mode can never send a request (AtriaAICoach.swift:405-422) — if the user has been looking for an AI coach, he has been looking at a disabled feature. (4) Sessions.swift:19781 suppresses aggregate-derived canonical strain unless `missingMinuteCount == 0`; for a user with a chronic backlog that is permanent suppression, even though the same DailyMetric struct carries representedMinuteCount/missingMinuteCount and could render a coverage-labelled partial. Worth revisiting as its own item. (5) AtriaHighlights (AtriaHighlights.swift:20-23) is literally two rules, one of which requires sleepPerformance >= 100 on two consecutive days — effectively unreachable for this user.

**Challenger 1 — refuted=True**

Every file:line citation checks out verbatim — I confirmed all of them. What fails is the inference, in three independent ways.

**1. The central assertion is false: two of the six named engines are not keyed on recoveryPercent or journal days.**

The claim states "every one of them is keyed on the two inputs this user's data cannot produce — a per-day `recoveryPercent` and manually-tagged journal days." Two of the six it names key on measured resting HR alone:

- `AtriaHighlights.lowerRestingHeartRate` (AtriaHighlights.swift:38-53) needs `rollups.first?.rhr` plus >=3 of the prior 7 `rhr` values. No recovery, no journal, no sleep, no motion. Wired live at AtriaTodayScreen.swift:1225.
- `healthDeviationDecision`'s RHR candidate (LocalNotificationScheduler.swift:1336-1348) needs only `DailyRollupVitals.Stat.n >= 3`. Wired live at LocalNotificationScheduler.swift:220.

And critically, `DailyRollupVitals.rhr` is built as `welfordStat(priorAndCurrent.compactMap { $0.restingHR.map(Double.init) })` over a trailing 28-day window (`sorted[max(0, index - 27)...index]`) at Sessions.swift:22036-22040 and 22145-22150. That is already a personal resting-HR band carrying mean/sd/n — structurally identical to the proposal's `AtriaQuietHeartRateBand {mean, sd, nights, windowDays}` — already driving a two-consecutive-day |z| rule through the already-honest `.healthDeviation` category. Proposal Rules (1) and (2) re-implement shipped machinery.

Also, `recomputeBehaviorInsights` already threads measured RHR into the journal engine: `let vitalDays = dailyMetricHistory.map { (day: $0.day, restingHR: $0.restingHR) }` passed as `dailyVitals:`, commented "Assessment P1.9: measured RHR days ride along so tags pair to signals that survive Recovery model bumps" (Sessions.swift:22838-22842, 22868). So even that engine is not purely recovery-keyed (it does still require journal days).

**2. The real mechanism is a clobber, not an absence.**

The app already derives per-day resting HR from bare HR wear with no sleep confirmation, no motion, no recovery, no journal. Sessions.swift:22577-22582:

```swift
let restingHR = confirmedMainSleep?.restingHR
    ?? reducedConfidenceInput?.restingHR
    ?? overnightRestingHR
    ?? overnightStableHR
    ?? computedToday?.restingHR
    ?? wearRestingHR
```

`wearRestingHR` is the min 10th-percentile HR across sessions attributed to the day by *end* day, and the comment at Sessions.swift:22477-22481 says this exists precisely so "today's rollup can e

_Corrections:_ The corrected root cause:

Atria is NOT missing an engine that turns measured heart rate into a statement. It already ships one, end to end, keyed on nothing but HR:

  wear sessions -> `wearRestingHR` (min 10th-percentile HR, no sleep/motion/recovery/journal required, Sessions.swift:22493-22507)
  -> `SavedDailyMetric.restingHR` (six-level fallback, Sessions.swift:22577-22582; admitted on `restingHR != nil` alone at 22652-22658)
  -> `DailyRollupStoreEntry.rhr` + `DailyRollupVitals.rhr` = trailing-28-day Welford mean/sd/n (Sessions.swift:22036-22040, 22145-22150)
  -> `AtriaHighlights.lowerRestingHeartRate` (AtriaHighlights.swift:38-53, live at AtriaTodayScreen.swift:1225)
     and `healthDeviationDecision` two-consecutive-day |z| >= 2 (LocalNotificationScheduler.swift:1336-1367, live at :220)
     delivered through the already-honest `.healthDeviation` category ("When a vital runs outside your typical range for 2 days", AtriaNotificationCategories.swift:100).

That is the proposal's "quiet-heart-rate band" plus its Rules (1) and (2), already built, already tested, already honest.

The defect is that its input is destroyed after it is correctly produced. The bulk historical rebuild derives `restingHR` from confirmed physiological main-sleep nights only (`let restingHR = night?.restingHR...`, Sessions.swift:21553), emits a row for every day that has any session rollup (day set at 21540; unconditional append at 21604-21606), and `mergeDailyMetricHistoryCancellable` seeds `merged` from `computed` before letting `existing` backfill (21804-21816). So on an HR-only night, the wear-derived RHR the morning path froze that day is overwritten with nil on the next rebuild, `welfordStat` falls below its 3-value minimum, and both RHR engines go silent.

The correct fix is small and does not need a new store, a new file, a new card, or a new notification rule:

1. Give the bulk builder the same fallback the morning builder already has — reuse the `overnightStableHR ?? computedTo

**Challenger 2 — refuted=True**

Verdict category is right (feature gap; nothing broken; not starved by the 4 h stall), and their inventory of surfaces with line cites checks out. But their stated MECHANISM is wrong at its center, and it is wrong in a way that would send the fix in the wrong direction.

They claim every engine is keyed on "a per-day recoveryPercent ... this user's data cannot produce," and cite hrv.lastReadyAnalysisAt stuck 8 days as structural proof. Both are false.

(1) recoveryV2 explicitly mints a percent WITHOUT HRV. AtriaAnalytics.swift:1396-1404 falls through to limitedEvidenceEstimateWithoutHRV (defined 1620-1691), which returns `percent: logisticRecoveryPercent(z: blendedZ)` at `.unverified` with HRV weighted exactly 0; and 1379-1385 falls through to limitedEvidenceEstimateWithoutSleepOrHRV (1566-1612), which returns a percent from RHR alone. A confirmed sleep DURATION by itself yields a z via populationSleepRecoveryZ (AtriaAnalytics.swift:1835-1847, the 7h/1.5 population norm) — no efficiency, no motion, no HRV needed. HR-only nights do not blank recovery; that is the whole point of those two functions.

(2) The device evidence proves he HAS both inputs. `atria.notification.morningSummary.lastScheduledDay = 2026-08-18` is written at exactly one place, Sessions.swift:12909, downstream of the guard at Sessions.swift:12861-12864 which requires `metric.recoveryPercent != nil && metric.hrv != nil && metric.sleepDuration != nil` for that day (key name pinned at Sessions.swift:9769). So on 2026-08-18 this user had a recovery percent AND an overnight HRV in ms AND a sleep duration. Their premise is contradicted by their own evidence bundle.

(3) They misread the HRV key. `atria.hrv.lastReadyAnalysisAt` (AtriaBLEManager.swift:1404) is the LIVE/awake HRV snapshot cadence marker, written only from applyHRVAnalysisResult when a live snapshot isReady (AtriaBLEManager.swift:5665, 24531) and consumed by shouldAttemptHRVAnalysis (AtriaBLEManager.swift:681-723). The HRV that feeds Recovery is `SleepHistorySnapshot.Night.hrv` (Sessions.swift:53496), composed from sleep-window RR across confirmed-sleep segments (Sessions.swift:409-515). Those are different pipelines. An 8-day-stale live marker is not evidence that the recovery input is starved — and (2) shows it is not.

So the outcome variable is present. The gap is on the other side of the equation.

_Corrections:_ CORRECTED MECHANISM: Atria has an OUTCOME and no MEASURED PREDICTORS. Every predictor variable in every statistical engine is hand-typed by the user; not one is derived from measurement — even though the app already computes half a dozen candidates.

- AtriaBehaviorImpact.swift:85 hardcodes `for tag in BehaviorJournalEntry.Tag.allCases` as the only predictor family, gated at minimumLoggedDays=5 / minimumComparisonDays=5 (:28-29). The recovery arm (`recoveryByDay`, :73) is populated for this user; the TAG arm is empty because he has never tagged a day.
- AtriaJournalInsights.insightsCancellable takes `questionAnswers`, which Sessions.swift:22849-22850 sources exclusively from `journalAnswers.answers` (typed journal). Gates at :105-106 (minimumSideDays=5, minimumSplitTotalDays=12).
- The remaining four are not journal-keyed and their gates are the real reason he sees nothing: PersonalBaseline.trustedMinimumSamples=14 with staleAfter=21 days (Insights.swift:26-27) blocks the whiteboard coach (Dashboard.swift:337), the `.personalBaseline` recovery tier, and the respiratory contributor (AtriaAnalytics.swift:1864); MonthlyReport.minimumDaysForStats=14 (AtriaMonthlyReport.swift:15); healthDeviationDecision needs Stat.n>=3 on RHR/HRV/resp (LocalNotificationScheduler.swift:1341-1350); AtriaHighlights is two hardcoded rules (AtriaHighlights.swift:20-23). These are BINARY gates — hide everything until N. The codebase already knows the better pattern and documents it at Insights.swift:302-317 (AtriaFitnessAge "Early estimate · day N of M", restingBaselineMaturityQualifierText) and ships it at AtriaSleepConsistency.minimumQualifiedNights=5 (Sessions.swift:55064). The insight engines simply never adopted a reduced-n tier.
- AI coach: agreed, not an engine. Defaults .off (AtriaAICoach.swift:31); local mode is one template restating today (:380-397); cloud renders a request preview only (:405-422).

DEEPER FINDING THEY MISSED (matters for where the new engine reads from): the ONE a


---

### Item 15 (with dispositions for leads a–e) — real-defect (refuted 2/2, confidence high)

**Root cause**

`recentDisconnectStorm` — the "back off after a RECENT early-disconnect storm" guard that fences every automatic background history-drain lane — is computed inline in five places as `defaults.integer(forKey: protectedR10EarlyDisconnectsKey) >= protectedR10EarlyDisconnectLimit || (stormAt within 300 s)`. Only the second disjunct carries a recency term. The first disjunct reads a counter that is MONOTONIC and effectively unclearable: `atria.protectedR10.earlyDisconnects` (AtriaBLEManager.swift:3319, limit = 2 at :3341) is incremented at AtriaBLEManager.swift:45156-45167 whenever a protected-R10 connection ends within 90 s, and is written to zero at only four places — `qualifyProtectedR10RecoveryIfNeeded` (:12649), which requires a proven R10 motion-frame stability window (callers :12291, :12509, :27142, :35646), plus three one-shot upgrade migrations (:6984, :7047, :7061).

The latch is self-sealing. The SAME threshold that makes the counter reach 2 also fires `shouldLatchProtectedR10RollbackForEarlyDisconnect` (:3814-3823) → `latchProtectedR10Rollback` (:12990-13010), which sets `protectedR10.rollback` and `passiveR10Status = activation_suppressed_observing_passive_r10`, i.e. Atria stops sending the R10 activation. No activation → no CRC-valid R10 frames → `qualifyProtectedR10RecoveryIfNeeded` can never run → the counter can never return to 0. The rollback-clearing / re-qualification paths (:4008, :4055, :4084, `promoteFallbackToProtectedV9ForLaunch` :3997-4020) deliberately reset `rollback`, `stableTransport`, `retryCount`, `proofChurnFailures` — but NOT `earlyDisconnects`. So on any strap that has settled into pure-HR / suppressed-R10 mode (this device: `workoutMotion.backfillPending=true`, imu_frames 0, steps frozen for days), `recentDisconnectStorm` is permanently true.

That permanently-true flag is a hard `guard ... else { return false }` in every automatic catch-up admission:
 • `shouldAllowConnectedRangeLossCatchUp` (:3646-3650) — P1b connected catch-up
 • `isFlushMaintenanceWindow` (:3677-3680) — P2 "flush while backgrounded/asleep" window and P4 productive-slice hold
 • `shouldResumeStrandedDrainingAuthority` (AtriaBLEHistoricalRecoveryPolicy.swift:637-640) — resuming a stranded `.draining` authority
 • `shouldAdmitAutonomousCursorAnchoredCatchUpStart` (AtriaBLEHistoricalRecoveryPolicy.swift:732-737) — autonomous background catch-up start
The P3 HR-independent maintenance ticker computes `flushEligible: !foregroundInteractiveMode && (flushMaintenanceWindow || connectedCatchUp)` (AtriaBLEManager.swift:16838-16845) from exactly those two, so it can never re-arm either. The only other lane, `scheduleRangeLossBackfillIfNeeded`, already early-returns on a connected WHOOP 4 with `gap_retained_transaction_unverified` (:16590-16603) — which is precisely the persisted `offlineSync.lastStatus` on the device. With the latch set, every automatic background drain lane is dead simultaneously, leaving only foreground/manual sync — matching the user's "catches up only when I foreground it" and a `rangeLossBackfillPending` that has stood since 2026-08-06.

The codebase's own policy layer proves this is a bug, not a design choice: the one correctly-written consumer of the same counter, `shouldIsolateRecentProtectedR10DisconnectStorm` (:3836-3849), pairs it with `lastDisconnectAge <= 5 * 60`, under a doc comment (:3832-3835) stating that a monotonic disconnect diagnostic "can never identify a current storm". The five drain-lane call sites omit exactly that recency term.

**Evidence**

- Atria/Atria/AtriaBLEManager.swift:3319 — `protectedR10EarlyDisconnectsKey = "atria.protectedR10.earlyDisconnects"`; :3341 `protectedR10EarlyDisconnectLimit = 2`; :3340 `protectedR10EarlyDisconnectWindow = 90`
- Atria/Atria/AtriaBLEManager.swift:45156-45167 — the ONLY increment: `let early = previousProtectedEarlyDisconnects + 1; defaults.set(early, forKey: Self.protectedR10EarlyDisconnectsKey)`, gated on `protectedActivationWasSent`, `!wasUserRequestedDisconnect`, `!atriaOwnedOfflineSyncDisconnect`, `connectedDuration <= 90`
- Atria/Atria/AtriaBLEManager.swift:12645-12651 — `qualifyProtectedR10RecoveryIfNeeded` is the only non-migration reset: `defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)`; its four callers (:12291, :12509, :27142, :35646) all require `protectedR10StabilityWindowIsProven` over R10 motion frames
- Atria/Atria/AtriaBLEManager.swift:6984, :7047, :7061 — the only other writes, all inside one-shot upgrade migrations (`migrateProtectedR10HistoryInterlockIfNeeded`, `migrateFailedProprietaryBatteryRefreshIfNeeded`, `beginRetiredBatteryProbeRecoveryIfNeeded`), each guarded by a `…MigrationKey`/`recoveryPending` bool that is set true on first run
- Atria/Atria/AtriaBLEManager.swift:3814-3823 `shouldLatchProtectedR10RollbackForEarlyDisconnect` fires at `previousEarlyDisconnects + 1 >= 2` → :12990-13010 `latchProtectedR10Rollback` sets `protectedR10RollbackKey` and `passiveR10Status = "activation_suppressed_observing_passive_r10"` and cancels the activation/stability tasks — so no further R10 frames, hence no qualification, hence no reset (self-sealing)
- Atria/Atria/AtriaBLEManager.swift:3997-4020 `promoteFallbackToProtectedV9ForLaunch` clears rollback/stableTransport/proofChurnFailures but never touches `protectedR10EarlyDisconnectsKey`; same at :4055-4062 and :4084-4091
- Atria/Atria/AtriaBLEManager.swift:10211-10217 (`stormForStrandedResume`), :10317-10322 (`fenceStormSignal`), :10728-10734, :14472-14478, :16798-16804 — five duplicated inline copies of `integer(forKey: protectedR10EarlyDisconnectsKey) >= protectedR10EarlyDisconnectLimit || (stormAt < 300 s)`; the count term has no age bound
- Atria/Atria/AtriaBLEManager.swift:3638-3658 `shouldAllowConnectedRangeLossCatchUp` — `guard …, !recentDisconnectStorm else { return false }`; :3670-3687 `isFlushMaintenanceWindow` — same hard guard
- Atria/Atria/AtriaBLEHistoricalRecoveryPolicy.swift:637-640 `shouldResumeStrandedDrainingAuthority` and :732-737 `shouldAdmitAutonomousCursorAnchoredCatchUpStart` — both `guard …, !recentDisconnectStorm else { return false }`
- Atria/Atria/AtriaBLEManager.swift:16838-16845 — the P3 maintenance ticker's `flushEligible: !foregroundInteractiveMode && (flushMaintenanceWindow || connectedCatchUp)`; both terms are false whenever the latch is set, so `shouldReArmRangeLossBackfillOnMaintenanceTick` never fires
- Atria/Atria/AtriaBLEManager.swift:3832-3849 — `shouldIsolateRecentProtectedR10DisconnectStorm` uses the same counter but ADDS `lastDisconnectAge >= 0 && lastDisconnectAge <= 5 * 60`, under a comment saying a monotonic diagnostic "can never identify a current storm" — the drain lanes omit that term
- Atria/Atria/AtriaBLEManager.swift:16590-16603 — the only other lane, `scheduleRangeLossBackfillIfNeeded`, sets `lastStatus = "gap_retained_transaction_unverified"` and returns on connected WHOOP 4; device `offlineSync.lastStatus` is exactly that value, so this lane is confirmed dead independently
- Device corroboration: `offlineSync.rangeLossBackfillPending = true` requested 2026-08-06 (13 days), `workoutMotion.backfillPending = true` (R10/motion never qualified), `keepalive.stallReconnects = 323` (link churn consistent with ≥2 sub-90 s protected disconnects at some point)

**Proposed fix**

Give the count term the recency bound its own name promises, and de-duplicate the five copies.

1. Persist the timestamp at the increment. Atria/Atria/AtriaBLEManager.swift:45165, alongside `defaults.set(early, forKey: Self.protectedR10EarlyDisconnectsKey)`, add `defaults.set(Date().timeIntervalSince1970, forKey: Self.protectedR10LastEarlyDisconnectAtKey)` (new key `"atria.protectedR10.lastEarlyDisconnectAt"` declared next to :3319).

2. Add one shared predicate in Atria/Atria/AtriaBLEHistoricalRecoveryPolicy.swift (beside the other pure policy fns, e.g. after :652):

```swift
nonisolated static func isRecentProtectedR10DisconnectStorm(
    consecutiveEarlyDisconnects: Int,
    lastEarlyDisconnectAtUnix: Double?,
    isolatedStormAtUnix: Double?,
    nowUnix: Double,
    earlyDisconnectLimit: Int,
    recencyWindow: TimeInterval = 30 * 60
) -> Bool {
    if let isolatedStormAtUnix, nowUnix - isolatedStormAtUnix < 300 { return true }
    guard consecutiveEarlyDisconnects >= earlyDisconnectLimit,
          let lastEarlyDisconnectAtUnix else { return false }
    let age = nowUnix - lastEarlyDisconnectAtUnix
    return age >= 0 && age <= recencyWindow
}
```
Note the `guard let lastEarlyDisconnectAtUnix else { return false }` — installs that already carry a latched count with no timestamp fail OPEN, which is what un-wedges this user's device on upgrade.

3. Replace all five inline expressions with a call to it: AtriaBLEManager.swift:10211-10217, :10317-10322, :10728-10734, :14472-14478, :16798-16804.

4. Belt-and-braces reset: in `didDisconnect` at AtriaBLEManager.swift:45156, add an else-branch — when `protectedActivationWasSent && connectedDuration > Self.protectedR10EarlyDisconnectWindow`, `defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)`. A connection that survived past the 90 s early-disconnect window is direct evidence the storm ended, and today nothing acts on it.

Deliberately NOT changed: `shouldIsolateRecentProtectedR10DisconnectStorm` (:3836) and `shouldLatchProtectedR10RollbackForEarlyDisconnect` (:3814) keep the raw counter — isolation/rollback are supposed to latch on lifetime evidence; only the drain-lane fences need the recency term.

**Test plan**

Pure-static policy tests, the idiom used by Atria/AtriaTests/AtriaBLEHistoricalRecoveryPolicyStructureTests.swift (scheme AtriaTests):

1. `testEarlyDisconnectStormExpiresWithRecencyWindow` — `isRecentProtectedR10DisconnectStorm(consecutiveEarlyDisconnects: 2, lastEarlyDisconnectAtUnix: now - 60, …)` is true; the same count with `lastEarlyDisconnectAtUnix: now - 13 * 24 * 3600` is false. This is the exact regression: today the second case is true forever.
2. `testLatchedCountWithoutTimestampFailsOpen` — count 2, `lastEarlyDisconnectAtUnix: nil` → false (upgrade path for already-wedged installs).
3. `testIsolatedStormWindowStillSuppresses` — count 0, `isolatedStormAtUnix: now - 100` → true (preserves the existing 300 s term).
4. `testStaleStormNoLongerFencesBackgroundCatchUp` — feed the stale-storm `false` into `AtriaBLEManager.isFlushMaintenanceWindow(rangeLossBackfillPending: true, foregroundInteractive: false, cleanOwnerState: .fallbackActive, activeExplicitWorkout: false, recentDisconnectStorm:)` and `shouldAllowConnectedRangeLossCatchUp(…)` and assert both now return true, mirroring the existing assertions around AtriaBLEHistoricalRecoveryPolicyStructureTests.swift:2146-2173.
5. Guard-pin source scan (same technique as AtriaBLERecoveryCadenceTests.swift:2970 and AtriaBLEHistoricalRecoveryPolicyStructureTests.swift:1183): read AtriaBLEManager.swift and assert `components(separatedBy: "protectedR10EarlyDisconnectsKey)\n                >= Self.protectedR10EarlyDisconnectLimit").count - 1 == 0`, so no sixth inline copy can be reintroduced.

No device soak needed to prove the fix — every guard on the path is a `nonisolated static` pure function.

**Noticed nearby**

Dispositions on the five assigned leads (all read, none is the headline defect):

(a) CONFIRMED but ZERO IMPACT — and the hypothesis is wrong about what it strands. `scheduleStaleArmedRangeLossBackfillReconciliation` (AtriaBLEManager.swift:17467-17498) does have the `clearableStatuses` guard that excludes the live `gap_retained_transaction_unverified`, but its body is DEAD CODE: after the guards it sets `staleRangeLossReconciliationInFlight = true`, then immediately `= false`, and calls `AtriaDebugLog`. It clears nothing (the comment at :17489-17492 says so deliberately: "Keep the durable request armed … only `newRows > 0` may ack it"). So even with the status guard fixed, nothing changes. It strands nothing. Do not "fix" this — it is a logger; if anything it should be renamed, since `schedule…Reconciliation` reads like an actor.

(b) publicationCheckpointMissing DOES have a recovery path, contrary to the lead. The generic terminal catch at AtriaBLEManager.swift:39840-39864 calls `scheduleTerminalConsumerDependencyRetry()` (:39938), an unconditional 15-minute in-process retry into `resumePendingFullDrainPublicationIfNeeded`. I checked the one plausible trap and it is closed: `shouldSeedTerminalConsumerCoverageFailureFromDiagnostic` (:40029-40042) only seeds the 24-hour suppression cache when the diagnostic contains "completionCoverageMismatch", so a `publicationCheckpointMissing` string cannot borrow the daily bound. What that lane genuinely needs is `peripheral?.state == .connected && lastAcceptedHRAt >= connectedAt` (:39700-39707) — during the 4 h dead window it is starved, not broken. The 08-14 diagnostic is stale telemetry: nothing clears `terminalArchiveFailureDiagnostic.v1` on success, only the coverage-retirement branch at :39754-39758 does. Worth a one-line cleanup, not a defect.

(c) The sequence-gap budget is NOT exhausted-and-stuck. `shouldSuppressAutomaticSequenceGapRetry` (AtriaBLEHistoricalRecoveryPolicy.swift:423-442) disarms when `currentFrontierUnix - parkedFrontierUnix >= 3600`. The park would have been stamped near the 2026-08-18 02:08 failure and `drainedThroughUnix` is 2026-08-18 21:22:38 — a ~19 h advance — so the breaker has already re-minted (`sequence_gap_fresh_attempt_minted`, :16510-16518). Consistent with `lastStatus` being `gap_retained_transaction_unverified` rather than `sequence_gap_parked_retained`.

(d) HRV is starved of RR, not gated by a bug. `shouldAttemptHRVAnalysis` (:680-723) requires `cleanWindowSeconds >= 300` and, after a failed attempt, `latestRRSampleAt > lastAttemptAt`. `cleanWindowSeconds` is the age of the oldest sample in `rrBuffer`, which is pruned at 305 s (:22112-22113), so with continuous RR the gate is satisfiable; with no RR (standard HR-only radio mode) it is never satisfiable and attempts stop — which is what "attempts ended 2026-08-15" looks like. Honest-but-invisible: the app shows no "HRV needs RR data" fail-closed state anywhere I could find. Worth a separate product item, not a code defect.

(e) memprobe logging is NOT in the shipping build — the only surviving mention in the whole app target is a comment (HistoricalArchive.swift:6483). The 17 MB of `atria-memprobe*.log` is orphaned output from an older build with no cleanup path, i.e. dead files nothing will ever reclaim. Separate small find, in item 12's territory.

Other things noticed in passing, worth a chip each:
• `AtriaHomeView.swift:6478 missedDataDurationText` and `:6491 catchUpProgress` are dead private computed properties (zero references repo-wide). Not user-visible, but `missedDataDurationText` would render "312.0 h" today because it treats the AGE of `rangeLossBackfillRequestedAt` as the DURATION of missing data — delete it before someone re-wires it into a banner.
• `reconcileRangeLossBackfillPendingWithArchive` sets `rangeLossBackfillStartedAt = now` on the CLEAR path (AtriaBLEManager.swift:16289), corrupting the "armed age" that :17475 and AtriaBLEEvidence.swift:85 report. Diagnostic-only today; would mislead a future support trace.
• `performSceneBackgroundMaintenance` (AtriaApp.swift:939-980) keys `syncRequired` on the raw `rangeLossBackfillPending`, so while that flag is stuck true EVERY scene-background opens a UIBackgroundTask and awaits `awaitRecoveredDataPublication` for up to 20 s. Harmless in isolation, but it is a real battery cost multiplied by a permanently-stuck ticket — another downstream consequence of the same wedge.

**Challenger 1 — refuted=True**

REFUTED on the decisive empirical test: `recentDisconnectStorm` is FALSE on the very device this claim purports to explain.

The field report's own device pull (/private/tmp/claude-501/-Users-amanpandey-projects-atria/f56c5754-9e6a-4337-abc2-510a269d32ef/scratchpad/pull/) contains four `com.adidshaft.atria` defaults dumps taken 2026-08-19 at 01:57, 02:06, 02:12 and 02:19. In every one:
- `atria.protectedR10.earlyDisconnects` = **0** (not >= 2). First disjunct FALSE.
- `atria.protectedR10.disconnectStormAt` — key **absent entirely** (grep count 0; key string confirmed at AtriaBLEManager.swift:3292). The expression is `(defaults.object(forKey:) as? Double).map { ... } ?? false`, so absence yields FALSE. Second disjunct FALSE.

So all five inline copies evaluate to `false`, and none of the four drain-lane guards (`shouldAllowConnectedRangeLossCatchUp`, `isFlushMaintenanceWindow`, `shouldResumeStrandedDrainingAuthority`, `shouldAdmitAutonomousCursorAnchoredCatchUpStart`) are tripped. The proposed fix would be a literal no-op for the reported symptom.

The code citations are textually accurate — I confirmed :3319, :3340-3341, :3814-3823, :3836-3849, :3646-3650, :3677-3680, :45156-45167, :12645-12651, the three migration resets, and all five duplicated expressions. The reasoning built on top of them is what fails.

FOUR INDEPENDENT ERRORS IN THE MECHANISM:

1. The central inference is falsified by the device. The claim states "on any strap that has settled into pure-HR / suppressed-R10 mode ... `recentDisconnectStorm` is permanently true." This device is in exactly that state — `cleanOwner = pure_hr_v8`, `rollback = true`, `streamSuppressed = true`, `workoutMotion.backfillPending = true`, imu_frames 0 — and the counter reads 0. Pure-HR mode is reached through many paths; this device's actual `atria.protectedR10.rollbackReason = "passive_reprobe_after_stable_hr"`, NOT `"repeated_early_disconnects"`. The early-disconnect latch never fired here. `passiveR10Status = "clean_owner_v8_pure_hr_active"`, not `"activation_suppressed_observing_passive_r10"` — the exact string the self-sealing story requires.

2. The "smoking gun" doc comment is misread — it says the opposite. AtriaBLEManager.swift:3832-3835 reads: "The lifetime disconnect diagnostic is intentionally monotonic and can never identify a current storm. Isolation requires the consecutive early-disconnect counter maintained by `didDisconnect`; that counter is cleared after a stable qualified epoch and ignores us

_Corrections:_ The salvageable grains, correctly scoped:

1. REAL BUT COSMETIC: the five inline copies at AtriaBLEManager.swift:10211-10217, :10317-10322, :10728-10734, :14472-14478, :16798-16804 are genuine copy-paste duplication of one policy expression. De-duplicating them into a single shared predicate in AtriaBLEHistoricalRecoveryPolicy.swift is defensible maintenance. It fixes no live defect — do not ship it as a fix for "catches up only when I foreground it," and do not pair it with the counter-reset in step 4.

2. REAL AND INDEPENDENTLY CONFIRMED: `scheduleRangeLossBackfillIfNeeded` (AtriaBLEManager.swift:16590-16603) does early-return on connected WHOOP 4 with `gap_retained_transaction_unverified`, and the device dump confirms `atria.offlineSync.lastStatus = "gap_retained_transaction_unverified"`. That lane is dead — but this is already known and already routed around: the P3 maintenance ticker deliberately drives `requestOfflineHistoricalSyncIfNeeded` (P1b/P2) instead, with an in-code comment at :16850+ explaining exactly that this lane "never reaches an arm."

3. LATENT, HYPOTHETICAL, NOT THIS DEVICE: because count >= 2 always coincides with `latchProtectedR10Rollback` firing (the same threshold drives both), a device that DOES latch via `repeated_early_disconnects` would hold count = 2 until something clears rollback/suppression and a subsequent connection qualifies. `promoteFallbackToProtectedV9ForLaunch` requires opt-in `allowFallbackRequalification` with a 30-minute cooldown and normal launch does not opt in, so recovery could be slow. If that is worth hardening, the correct minimal change is to add the timestamp at the increment (step 1) and use it ONLY in the four drain-lane fences via a new predicate — with NO default-open branch (absent timestamp should fail CLOSED, preserving today's behaviour) and NO widening beyond the existing 300 s term. Drop step 4 entirely; it is the one piece that touches shared state the claim promised not to touch.

Correct root cause 

**Challenger 2 — refuted=True**

Their code observations are accurate but their causal chain has two broken links, its premise is unevidenced on this device, and its claimed consequence is contradicted by the dump. What they found is a downstream symptom of a deeper, fully-provable misclassification bug in `didDisconnect`.

WHAT THEY GOT RIGHT (verified):
- The five inline `recentDisconnectStorm` computations exist exactly as described and only the second disjunct carries recency: AtriaBLEManager.swift:10212-10218, :10317-10322, :10729-10734, :14473-14479, :16798-16804. All feed hard `guard ... else { return false }` fences at :3646-3650, :3677-3680, AtriaBLEHistoricalRecoveryPolicy.swift:637-640 and :732-737.
- `atria.protectedR10.earlyDisconnects` (:3319, limit 2 at :3341) is written to zero only at :6984, :7047, :7061 (one-shot migrations) and :12649 (`qualifyProtectedR10RecoveryIfNeeded`). Nothing zeroes it on a healthy long connection.
- `scheduleRangeLossBackfillIfNeeded` really does early-return on `gap_retained_transaction_unverified` at :16591-16601.

WHERE IT BREAKS:
1. "No activation → no CRC-valid R10 frames → qualify can never run" is FALSE. There is a passive qualification path at :35630-35650 inside `recordProtectedR10EvidenceIfNeeded` that runs specifically when `!protectedR10ActivationSent`, is gated on `!protectedR10StableTransportKey` (which `latchProtectedR10Rollback` :12994 has just set false), and calls `qualifyProtectedR10RecoveryIfNeeded(status: "receiving_crc_valid_passive")` after 90 s of passively-received frames — clearing the counter with no activation at all. `latchProtectedR10Rollback` :13006-13008 explicitly preserves the passive stream ("Never unsubscribe, cancel, rediscover, or reconnect here"), and :3928-3931 documents the persisted activation lease that keeps the strap in motion mode across reconnects. The latch is therefore not self-sealing.
2. They cite the doc comment at :3833-3836 as proof the drain lanes are wrong. It says the opposite: the *lifetime* diagnostic is the monotonic one, and the early-disconnect counter is the correct signal because it "is cleared after a stable qualified epoch and ignores user/app-owned edges." That last clause is the actual contract — and it is the clause the code violates (see below).
3. The premise is unevidenced. Neither the pulled dump nor `.claude/field-report-2026-08-19.md` contains `atria.protectedR10.earlyDisconnects`, `protectedR10.rollback`, or `passiveR10Status`. "This device has the latch set" is an infer

_Corrections:_ DEEPER, FULLY PROVEN DEFECT — `didDisconnect` charges Atria's OWN recovery cancels as adversarial short disconnects.

`Atria/Atria/AtriaBLEManager.swift:45045-45047` computes the app-owned-cancel signal:
    let lastAppCancelAt = defaults.double(forKey: "atria.ble.lastAppCancelAt")
    let recentAppCancel = lastAppCancelAt > 0 && abs(disconnectNow.timeIntervalSince1970 - lastAppCancelAt) <= 15
It is stamped for every app-owned cancel by `cancelPeripheralConnection` (:22671-22672, alongside `backgroundReconnectFence.markAppOwnedCancellation`), and there are ~20 such call sites (watchdog fresh scans, radio-mode cutovers, silent-stream rebuilds, owner cutovers…). The codebase knows what it means: the comment at :45198-45200 says "`recentAppCancel` covers intentional owner cutovers and watchdog resets", and it is correctly excluded from the interrupted-full-drain decision at :45205.

Two penalty branches in the same function omit it:

(1) :45159-45165 — the protected-R10 early-disconnect penalty
    if motionHandshakeDiagnostic == nil,
       protectedActivationWasSent,
       !cleanOwnerProofWasActive,
       !wasUserRequestedDisconnect,
       !atriaOwnedOfflineSyncDisconnect,
       connectedDuration > 0,
       connectedDuration <= Self.protectedR10EarlyDisconnectWindow {
`wasUserRequestedDisconnect` is only true for explicit `disconnect()` (:22525) and `forgetSavedStrap` (:23195); `atriaOwnedOfflineSyncDisconnect` only covers history-sync ownership (:45071-45074). An Atria watchdog cancel is neither. So it increments (:45166-45167) and, at count 2, calls `latchProtectedR10Rollback(reason: "repeated_early_disconnects")` (:45170-45175 → :12990-13010), which sets `protectedR10.rollback` and `passiveR10Status = activation_suppressed_observing_passive_r10`. This directly violates the documented contract at :3833-3836 ("ignores user/app-owned edges").

(2) :45220-45224 — the official-app coexistence verdict
    } else if !wasUserRequestedDisconnect && connectedDuration >


---
