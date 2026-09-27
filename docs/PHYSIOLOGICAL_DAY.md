# Physiological day

Audit 2026-09-24 (branch off `dev` e7281acb).

## The model

A day runs from one main-sleep wake to the next. Its anchor is the person's main sleep wherever it falls on the clock. A shifted sleeper who sleeps 13:15–19:15 starts their day at 19:15, and an afternoon sleep is real sleep.

- **Naps** never open a day. The nap sources, or anything 3 h or shorter, are excluded by `confirmedSleepIsPhysiologicalMainSleep`.
- **No sleep:** the day rolls at wake + 24 h + 30 min settlement grace, then every 24 h. It never rolls at midnight.
- **Midnight** is not a boundary for any live metric.

One authority owns the boundary: `AtriaPhysiologicalCycle.boundaryEligibleMainSleeps` (`Sessions.swift`). Everything else delegates to it:

- `AtriaPhysiologicalCycle.current`, the live cycle;
- `AtriaPhysiologicalDay`, Today's window;
- `AtriaHistoricalPhysiologicalCycle.resolve`, a past day by its wake date;
- recovery attribution;
- step receipts;
- the widget day fence.

## Per metric

| Surface / metric | Current behaviour | Right? | Fix |
|---|---|---|---|
| **Today window** (live strain, steps, workouts) | `AtriaPhysiologicalDay`, from the confirmed main-sleep wake to now. Naps are excluded. No-sleep fallback applies. | Yes, except for split nights | See next row |
| **Split night**: two stored main sleeps with a brief wake between (e.g. 23:00–02:00 + 02:30–07:30) | Each wake opened a cycle, which created a 02:00→07:30 "day" of pure night. The historical resolver takes the *last* wake of a civil day, so that interval belonged to no day. When the halves straddled midnight, the evening half's 23:50 wake became that date's anchor, and the whole waking day was attributed to the night. | **No** | **Fixed.** `bridgingBriefAwakenings`: a main sleep followed by another main sleep starting < 90 min later (`resumedSleepMinimumSeparation`, the app's own bound for a separate sleep episode) is not a boundary. The final wake starts the day. Sleep records are unchanged. |
| **Past days** (Activity, strain history `cycleStrainByDisplayDay`) | `AtriaHistoricalPhysiologicalCycle`: the wake on that date to the next wake. A civil interval is used only as a labelled fallback when no boundary exists. | Yes (after the split-night fix) | — |
| **Strain** | The live ring is cycle-windowed. Detail charts use cycle strain per wake day and fall back to civil values for days without one. | Yes | — |
| **Recovery / overnight HRV** | Anchored to the latest completed main sleep. HRV comes from that sleep's window. The 04:00–11:59 clock gate applies only when no sleep was ever confirmed (`initialFallback`). | Yes | — |
| **Steps, Today tile** | Current-cycle receipts ("since your wake"); live R10 gyro steps persist through the step ledger. When the power policy turns live R10 off (strap below 15 %, phone low/hot, Low Power Mode) steps come only from the history bank, but the tile read like any other partial state. | Partly | **Fixed (display).** While paused, a partial count reads "Live steps paused · strap 12% · from strap history" (or "History through 8:12 AM · live paused …") with a footnote that it grows as history syncs. An undrained bank stays "--", never 0. Complete days and the catch-up note keep their copy. |
| **Steps, week chart** | Calendar-day totals computed exactly from shards (`AtriaCivilDayStepAuthority`, owner decision 2026-08-26/27). The caption says "Bars are calendar days · the count above is since your wake". **Today's in-progress bar was judged against the goal, so it went red every morning. Partly covered days (strap off, charging, history not drained) looked like whole-day totals.** | Partly | **Fixed (display).** Today, days under 80 % row coverage, and receipt-only days are drawn faded with an at-least `+` ("4,210+"). They are never coloured as a missed goal. A partial day that already met the goal still shows met, because the count is a lower bound. 80 % is a coverage ratio, the same for every wearer. |
| **Stress daily distribution** ("today vs typical", daily trend) | Keyed by `startOfDay`, so "today" resets at 00:00. A shifted sleeper's single waking day (19:15 → 13:00) is split across two dates. | **No** for shifted sleepers | **Not fixed.** The archive is persisted and keyed by civil date. The fix is to key each sample by the physiological display day (`startOfDay(cycle.start)`) at record time. The stress monitor then needs the current cycle start, and old days need a one-time re-key or a version bump. |
| **Night interruption prompt** ("what was it?") | Shown only 04:00–13:00 local time. A 19:15 waker was never asked. | **No** | **Fixed.** Shown for 12 h after the latest main sleep's wake, whatever the clock says (`AtriaNightTimelineSource.morningPromptIsDue`). |
| **Morning check-in** | Anchored to the main-sleep wake (within 18 h). Falls back to a 04:00–15:00 clock window only without a sleep. | Yes | — |
| **Sleep consistency** | Circular statistics; "no typical bedtime" when bimodal (#41). | Yes | — |
| **`DailyRollupStoreEntry.bedtimeMinutes`** | Stored with a noon anchor (`< 12:00 → +24 h`), which splits an afternoon cluster. | Latent | **Not fixed.** Consumers must use circular statistics (as `AtriaNightBaseline` does). Re-anchoring changes a stored field. |
| **Bedtime suggestion** | Offered only after 21:00 local time. | No for shifted sleepers | **Not fixed.** It should key off the learned sleep onset. |
| **Pending review before cycle start** | `pendingSleepReviewBelongsToCurrentCycle` has a fallback clause that requires wake ≤ 11:00. | Minor | **Not fixed.** It affects only a review that ended *before* the current cycle started. |

## Remaining limit

A split night whose second half is shorter than 3 h is not a main sleep. For example, 23:00–04:00 then 04:30–05:30. Its first wake still opens the day. Linking it needs the resumed-sleep machinery (≥ 90 min separation today) to accept short continuations.

## Tests

`AtriaPhysiologicalDayScenarioTests` covers:

- a normal night;
- a shifted afternoon sleeper (Asia/Kolkata 13:15–19:15);
- a split night at 2 am, including a split across midnight;
- naps;
- a no-sleep day;
- a biphasic sleeper whose two sleeps stay distinct.

`AtriaNightMinuteBuilderTests` covers the sleep-anchored morning prompt. `AtriaStepsWeekChartPartialTests` covers the partial-bar policy, and `AtriaStepsLivePausedPresentationTests` covers the live-paused step copy.
