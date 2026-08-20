# Atria UI Declutter + Edge-to-Edge Implementation Plan

Synthesized from the six per-surface audits (today, home-overview, overview-sections, vitals, activity, stress-trends, strap-status). Every change below is presentation-only; every honesty/provenance string is **relocated** (detail sheet, About sheet, or accessibilityLabel), never deleted, per the issue #37 precedent. Findings marked `keep` in the audits are treated as do-not-touch guardrails (listed at the end).

---

## 1. Ranked changes (highest visible impact first)

### R1 — Kill the permanent calibration narration in the pinned notice band (every tab, up to 14 days)
- **Surface:** home-overview
- **Refs:** `AtriaHomeView.swift:4924` (RHR/HRV calibration titles, strings built in `Insights.swift:317`/`:327`), `AtriaHomeView.swift:4615` (VO₂ estimating line), band host `AtriaHomeView.swift:4601`
- **Change:** Stop rendering the three rotating calibration-progress sentences in the pinned 40pt band; route each maturity qualifier to its metric's info affordance (AtriaAboutMetricSheet / AtriaMetricProvenanceCard). Existing accessibilityLabel at `AtriaHomeView.swift:4937` already carries the full VO₂ disclosure and stays.
- **Why safe:** Pure relocation of maturity qualifiers to the metric they qualify; band's sync-truth states (`4995`, `5043`) are untouched here. No model change.

### R2 — Delete the verbatim footer duplicate on six tall glance cards
- **Surface:** overview-sections
- **Refs:** `AtriaOverviewSections.swift:6731` (footer `Text(detail)`), duplicate of the header detail at `:6604`
- **Change:** Remove the footer re-render of the identical detail string on cards without a sparkline/ring (HR Zones, Workouts, Strain vs typical, Calories, Resp rate, Stress).
- **Why safe:** The exact same string remains on the same card 100pt above. Zero information loss.

### R3 — Collapse the Today's Plan triple-print of one cue + redundant lane legend
- **Surface:** overview-sections
- **Refs:** `AtriaOverviewSections.swift:8424` (cueText, dup of headline `:8258` and detailText `:8392`), `:8430` ("Recover · Hold · Push" caption, dup of the lane's own segment labels `:8404-8406`)
- **Change:** Delete the bottom cue row and the legend caption.
- **Why safe:** Both are second/third renders of content the same card already shows; the lane segments remain labeled.

### R4 — Gate the Today settlement row to actionable states only
- **Surface:** today
- **Refs:** `AtriaTodayScreen.swift:3374` (titles from `AtriaSleepSettlementPresentation.swift:36-45`)
- **Change:** Render the settlement row only in settling/review states; the terminal "Sleep window saved" + freshness stamp move to the sleep detail sheet.
- **Why safe:** Terminal-state fact relocated, not removed; sleep chip already shows hours + need all day. Presentation gating only.

### R5 — Slim the Daily-brief prose stack; relocate the calibration clause
- **Surface:** today
- **Refs:** `AtriaTodayScreen.swift:3643` (detail built in `Dashboard.swift:359/380`; headline `Text(title)` at `:3636`)
- **Change:** Relocate the "HRV is still calibrating…" provenance clause to AtriaMetricProvenanceCard / recovery detail sheet + accessibilityLabel (mandatory per #37); reduce the three prose tiers (headline / coach sentence / target pill) — final composition needs design judgment (see Deferred D2).
- **Why safe:** Whiteboard rows above already show the same HRV/RHR/TRIMP numbers; provenance relocates to named destinations.

### R6 — Compact all sentence-length prose rendered *inside* Activity chart plots
- **Surface:** activity
- **Refs & new copy:** `AtriaActivityMonitor.swift:2752` → "No HR recorded in this window"; `:963` → "No stress readings since waking"; `:960` → "HR-only estimate · lower confidence"; `:955` → "Outside the 2-day detailed-history window"; `:948` → "Saved history couldn't be read"; `:2753-2754` → "History unavailable for this window"; `:989` → "Outside the 2-day detailed-history window"; empty-day copy `:1832` → "Detected workouts and sleep appear here. Use Add to log your own."
- **Why safe:** Full sentences already live in the cited accessibility values (`stressAccessibilityValue :2795/:2800/:2804`, `heartRateAccessibilityValue :2779`); shortened forms preserve the honest fact (measured vs HR-only, retention window) on-surface.

### R7 — Overnight HR-load card: delete the duplicate render, tuck the disclaimer
- **Surface:** vitals
- **Refs:** `AtriaHealthScreen.swift:2946` (ContentUnavailableView description) duplicated by the unconditional `Text(projection.availability.detail)` at `:2951`; the 0–3 scale disclaimer (string at `:2513`) at `:2951`; provenance subtitle `:2809` (string `:2503`); band caption `:2938` → "Typical resting 48–56 bpm"
- **Change:** Remove the double render in non-ready states; move the two-line disclaimer and "Observed HR · personal baseline" subtitle to the detail sheet / accessibility (inspector subtitle `:2984-2986` already covers the band explanation); shorten the band caption to the numeral.
- **Why safe:** `:2946` is a literal duplicate; disclaimer/provenance relocate to existing destinations. Enables the later chart-height raise (Deferred D8).

### R8 — Drop the third provenance statement on the sleep-stage card
- **Surface:** vitals
- **Refs:** `AtriaVitalsCollectionSections.swift:6594`; retained markers: `stageDisplayLabel :6552` + "Low confidence" chip `:6555`; a11y `:6656`
- **Change:** Remove the "Motion not available — stage boundaries are estimates…" caption; keep exactly one on-card marker (the chip) and route the sentence to the sleep detail sheet / info affordance.
- **Why safe:** Two other on-card provenance markers remain; full caption already in the accessibilityLabel.

### R9 — Tuck the relative-skin blocker block off the Live Health Monitor
- **Surface:** vitals
- **Refs:** `AtriaVitalsCollectionSections.swift:824` (headline+detail from AtriaRelativeSkinSignalPresentation), mounted at `AtriaHealthScreen.swift:1490`
- **Change:** Move the three-line "Relative skin signal / Building personal baseline · 2 of 5 nights / Experimental · uncalibrated" block into the skin detail/info affordance; the Skin temp tile keeps its own status line.
- **Why safe:** Number-free blocker prose relocated; the tile's status line still discloses state on the main surface.

### R10 — De-duplicate the stress provenance chain (up to 3 renders in one viewport)
- **Surface:** stress-trends
- **Refs:** hero detail `AtriaStressDetailView.swift:581`; intervention dup `:426` → "\(minutes) min elevated"; gauge-caption dup `:883`; timeline body repeat `:667`; source string `AtriaStressMonitor.swift:4109`; card caption `:600` → "Timeline" (reuse `.empty` title at `:1257`); threshold legend `:903` → About sheet; "Live" dup `:760` (pill at `:552-566` wins)
- **Change:** Keep exactly one on-screen provenance instance (the hero detail line, shortened to "HR + HRV" / "HR-only · lower confidence"); delete the `:426`, `:883`, `:667` repeats; move "learning baseline"/"activity-adjusted" to AtriaAboutMetricSheet + the drag-inspection card (`AtriaStressDetailView.swift:1513-1514`, already present) + accessibilityValue.
- **Why safe:** heroAccessibilityLabel (`:178`) already carries score/zone/provenance; the ⓘ button opens AtriaAboutMetricSheet(.stress). **Hard constraint:** keep the literal "HR-only" token — `AtriaHomeView.swift:4715` substring-matches it (see Conflict C3).

### R11 — Morning sleep-review: shorten the provenance subtitle; resolve the duplicate confirm surface
- **Surface:** overview-sections
- **Refs:** `AtriaOverviewSections.swift:1140` → "HR-only estimate" (instruction dup of Confirm button's accessibilityHint `:1248`); duplicate Confirm/Adjust block in the Morning journal `:14797` (`shouldShowConfirmSleep :14678`, "Confirm if this sleep looks right." `:14707`) vs AtriaSleepReviewCard `:1240`
- **Change:** Shorten `:1140` now; the `:14797` duplicate decision surface needs a product call on which surface owns confirm before deletion (Deferred D5).
- **Why safe (`:1140`):** Provenance stays visible in compact form; instruction lives in the button + hint.

### R12 — Terse imperatives for the strap-not-connected banner
- **Surface:** home-overview
- **Refs:** `AtriaHomeView.swift:13954` (one of ~12 two-sentence strings at `:13904-13994`, rendered `:14030`), a11y `:14065` preserved
- **Change:** Per-diagnosis terse imperative ("Bring your strap closer", "Charge your strap", "Close the WHOOP app"); full sentences relocate to the existing "?" connection-guide sheet and accessibilityLabel.
- **Why safe:** Guide sheet destination already exists for bluetoothLink/appCoexistence; a11y keeps title+action.

### R13 — Edge-to-edge: full-bleed the Activity day timeline charts (shipped precedent)
- **Surface:** activity
- **Refs:** `AtriaActivityMonitor.swift:2487` (dayTimelineCard `.padding(12)`), charts at `:2477-2485`; precedent `.padding(.horizontal, -12)` at `:3574` ("2026-08-05 width audit")
- **Change:** Apply the same negative horizontal padding to heartRateTimelineChart and stressTimelineChart; header text and span strip keep the 12pt inset.
- **Why safe:** Follows the established in-repo full-bleed convention on the same file.

### R14 — Edge-to-edge: full-bleed the Vitals trend chart (shipped precedent)
- **Surface:** stress-trends
- **Refs:** `AtriaTrendChart.swift:214` (card `.padding(16)`), chart at `:151`; precedent `AtriaStressDetailView.swift:664` and `:1002`
- **Change:** `.padding(.horizontal, -16)` on the plot only; header/selectors stay inset.
- **Why safe:** Same pattern already shipped on two stress-detail cards.

### R15 — Gutter alignment: overview section card + report sheets to the 12pt app gutter
- **Surface:** overview-sections
- **Refs:** `AtriaOverviewSections.swift:3215` ("Today at a glance" `.padding(16)` → 12 horizontal; precedent `:9225-9227`), `:5438` (weekly report `.padding(18)` → 12 horizontal), `:5875` (monthly report `.padding(18)` → 12 horizontal)
- **Why safe:** Numeric padding change matching the documented 2026-08-05 width-audit gutter; vertical padding untouched.

### R16 — Vitals live stress chart: delete the legend row, color the axis (precedent exists)
- **Surface:** vitals
- **Refs:** `AtriaVitalsCollectionSections.swift:3921-3925` (legend), zone RectangleMarks `:4153-4167`, y-axis `:4237-4248`, a11y `:3926`; precedent colored axis `AtriaHealthScreen.swift:2909-2911`; chart 172 → ~210pt
- **Why safe:** Chart already encodes zones twice; zone-word definitions stay in the info sheet + a11y. Chart-encoding change → visual sign-off before ship (Deferred D7 gates the height change).

### R17 — Sync footer: numbers-first status line
- **Surface:** home-overview
- **Refs:** `AtriaHomeView.swift:6156` detail → "Through 4:12 PM · 3h 24m behind"; state icon `:6172-6174` retained; a11y `:6199` keeps the full sentence; the progress-capsule chart at `:6186` is Deferred D6
- **Why safe:** Reassurance clauses ("live HR current", "paused · resumes…") relocate to a11y + Strap detail screen; icon still carries active/paused.

### R18 — Saved-workout banner de-chrome
- **Surface:** home-overview
- **Refs:** delete non-tappable "Review" chip `AtriaHomeView.swift:6723`; delete "Confirm the type to save" decision-strip narration `:6830` (dup of the "Confirm type" button `:6736`; signal-quality half stays as icon + one word); tuck "Strap HR" capsule `:6597` (repeat `:6930`) to the banner a11y `:6625`; provenance suffix `:6714` (" from strap HR") to a11y `:6751`; `:288` → "Waiting for a steadier rise"
- **Why safe:** All duplicates of on-card controls/labels or single-source provenance with existing a11y destinations. Frees space for the sparkline in Deferred D6.

### R19 — Detail-sheet methodology consolidation (strain, sleep planner, contributor map, chart captions)
- **Surface:** overview-sections
- **Refs:** four methodology captions under strain-detail cards `AtriaOverviewSections.swift:10642, 10749, 10795, 10834` → AtriaMetricMeaningSheet/AtriaAboutMetricSheet via the info button `:9208`, max one line per card; triple caption stack under detail charts `:11698` → compact inline legend key + hint into scrub callout/a11y; planner methodology `:14235` → "Projected need 8h 30m · updates with today's strain"; `(goal detail)` `:14248-ish (line 14248 entry: 14324 sibling)` — specifically `:14235`, `:14324` → "Smart window may wake you early in light sleep; wake-by is the fallback.", and the goal-detail line → "Assumes 85% efficiency · anchored to wake-by"; contributor-map legend `:12600` → "Right supported · left pulled down"; education sentence `:12620` deleted (lives in info affordance); "Deeper context" dup `:12177` deleted; report-sheet filler `:5395/:5400` deleted; monthly eyebrow dup `:5817` deleted (weekly precedent comment `:5365-5368`)
- **Why safe:** Every relocation targets an existing info affordance; all are inside sheets (lower stakes than always-visible surfaces).

### R20 — Workout detail sheet copy + label fixes
- **Surface:** activity
- **Refs:** zone-header methodology `AtriaActivityMonitor.swift:4354` → info affordance (a11y `:4430` keeps recorded-time framing); zone blocker `:4372` → "Not enough recorded heart rate to place time in zones." (a11y `:4387`); muscular-load explainer `:5070` → AtriaAboutMetricSheet; sleep-sheet third provenance repeat `:5224` deleted (hypnogram + stage header `:5239` remain); stress-chart caption dup `:3601` deleted (caption `:3593` + container a11y `:3540` remain); mislabeled header `:4920` `"%.1f min"` → "low 0.4 / high 2.6" or drop (a11y `:5015` keeps values)
- **Why safe:** Dupes and relocations with cited surviving markers; `:4920` is a clarity fix on a label that currently reads as minutes.

### R21 — Strap screen copy pass
- **Surface:** strap-status
- **Refs:** disconnected hero `AtriaStrapScreen.swift:295` → 3-4-word states ("Bluetooth is off" / "Bluetooth access needed" / "Bluetooth unavailable — retrying" / "Out of range — scanning"); full sentences move verbatim into the existing connection-guide sheet (`:314-321`) + hero accessibilityLabel; stream detail `AtriaHomeView.swift:9337` (rendered `AtriaStrapScreen.swift:348`) → per-state short forms ("HR arriving" / "Too low for live HR" / "Reduced detail until charged" / "Connected — no live HR" / "State pending"); battery detail `AtriaHomeView.swift:9170` → "Charging"/"Not charging"/"Full" (keep "Charge unavailable" visible — provenance); coexistence healthy-state detail `AtriaStrapScreen.swift:73` → a11y only (tile a11y `:436` already concatenates; **risk states keep visible detail unchanged**); Mode cadence jargon `:59` → About sheet; "Linking to \(device)" `AtriaHomeView.swift:13357/:13375` → "Linking…" (fixes 0.6-scale micro-text at `:13794`)
- **Why safe:** Every blocker relocates to guide sheet/a11y; risk-state truths explicitly stay on-surface.

### R22 — Remaining Today micro-copy with existing destinations
- **Surface:** today
- **Refs:** `AtriaTodayScreen.swift:1531` → "Notifications off" (a11y `:1549` already verbatim); `:4158`/`:4177` → "3 of 14 nights" / "3 of 14 days" (a11y `:4279` + detail sheets keep "calibrating"); `:1738` → "Aug 19 · 7h 12m" (qualifier to sleep detail sheet + ring a11y `:2274-2280`; date stays as the honesty anchor); `:2727` → "Last: Strength · Tue"; `:2785` → "Median needs 7 days" (matches sibling vocabulary `:2522`); `:4192` → "need unavailable" (reason to sleep detail sheet); `:3305` → "Showing 6 of 8 metrics."; `:2206` percent-of-need dedupe by extending the `suppressesDetail` rule at `:1046` to the semantic pair (center "82% of need" wins; chip's "of 8h 58m need" `sleepNeedDetailText :1640` suppressed when sleep is center)
- **Why safe:** Every trim has a cited a11y/detail-sheet destination; the date anchor is retained.

### R23 — Stress/trend empty-state and footnote shortenings
- **Surface:** stress-trends
- **Refs:** `AtriaStressDetailView.swift:1008` → a11y `:1069` + About sheet (legend row stays); `:748` disclaimer → About sheet + card a11y; `:1013` → "Building history · \(framed.count) of 3 measured days"; `:1105` → "Typical appears after 3 measured days"; `:657` → "Waiting for live heart-rate readings"; `:826` three variants → "Starts at the 2nd reading" / "Starts at the 2nd HR-only estimate" / "Starts with the first 5-min estimate"; `AtriaTrendChart.swift:699` → keep only `:697`'s "Not enough X yet"; `:199` → "Comparison fills in with more saved days"; Vitals siblings: `AtriaVitalsCollectionSections.swift:3950` → "Keep wearing your strap — first estimate after a complete 5-minute window."; `AtriaHealthScreen.swift:1111` → "Next sleep is detected automatically."; `:1866/:1877/:1889/:1898/:1910` hint chips → state-only ("Low", "↑ elevated", "↓ below typical", "↓ 1h 20m debt"; advice clause into each metric's existing detail sheet); `:3125` "6 qualified nights" → a11y `:3220`
- **Why safe:** Measured-vs-HR-only distinctions survive in the short forms; all long forms go to About sheets/a11y.

### R24 — Remaining structural padding cleanups (small numeric edits)
- **Surfaces:** today / overview-sections / activity / vitals
- **Refs:** `AtriaTodayScreen.swift:3682` + `:3674` (flatten one Daily-brief inset layer); `AtriaOverviewSections.swift:8288` (plan card 16→12 + let lane/strip span), `:6646` (glance card 12→10 horizontal, sparkline footer `:6712` to inner edges), `:674` (disconnected panel 18→12-16), `:14872` + `:14825` (journal card 16→12, drop one nesting level), `:5174` (tri-ring strip stretch); `AtriaActivityMonitor.swift:5201` (sleep sheet 16→12 + hypnogram -12 bleed), `:3871` (workout sheet 16→12), `:4790` (add-workout 16→12), `:4210`/`:4228` (route-map full-bleed, clip to card radius); `AtriaHealthScreen.swift:1517` (remove 2pt grid inset), `:845` (scope selector 4pt inset); `AtriaVitalsCollectionSections.swift:6653` (stage-timeline plot bleed, plot lines `:6579-6588` only); `AtriaStressDetailView.swift:492` (chart-bearing cards span full width / extend plot negative padding); `AtriaHomeView.swift:4757` (topChrome 16→12; widens the 172pt chip at `:13809/:13794`), `:4897` (contentMargins 16→12; spacing constraint at `:4849` still holds: 32 ≥ 24), `:6380` + `:6196` (status banners → full-bleed bands, matching `:4599`)
- **Why safe:** All numeric padding/bleed edits with cited constraints; no layout system change. Exception flagged: `AtriaOverviewSections.swift:11517` (see Conflict C2).

---

## 2. Batch 1 — one implementation pass (low-risk, highest impact)

All items are duplicate-prose deletion, verbose-copy relocation to an existing destination, or edge bleed following a shipped in-repo precedent. Each preserves a cited a11y/detail-sheet copy of the honesty content.

| # | Change | Refs |
|---|--------|------|
| B1 | Delete glance-card footer verbatim duplicate (R2) | `AtriaOverviewSections.swift:6731` (dup of `:6604`) |
| B2 | Delete Today's Plan cue triple-print + lane legend caption (R3) | `AtriaOverviewSections.swift:8424`, `:8430` |
| B3 | Tuck calibration notices out of the pinned band (R1) — band structure itself untouched | `AtriaHomeView.swift:4924`, `:4615` (a11y `:4937` stays) |
| B4 | HR-load card: delete double render, tuck disclaimer + subtitle, shorten band caption (R7) | `AtriaHealthScreen.swift:2946`, `:2951`, `:2809`, `:2938` |
| B5 | Delete third sleep-stage provenance statement (chip + label remain) (R8) | `AtriaVitalsCollectionSections.swift:6594` |
| B6 | Compact all in-plot Activity prose to the audited short forms (R6) | `AtriaActivityMonitor.swift:2752, 963, 960, 955, 948, 2753-2754, 989, 1832` |
| B7 | Stress detail dedupes: intervention repeat, gauge-caption repeat, card caption, "Live" dup (R10, dedupe subset only — hero shorten deferred to batch 2 under the "HR-only" token constraint, C3) | `AtriaStressDetailView.swift:426`, `:883`, `:600`, `:760` |
| B8 | Edge bleed with shipped precedent: Activity day timeline + Vitals trend chart (R13, R14) | `AtriaActivityMonitor.swift:2487` (per `:3574`); `AtriaTrendChart.swift:214` (per `AtriaStressDetailView.swift:664/1002`) |
| B9 | Gutter alignment 16/18→12 on overview section card + report sheets (R15) | `AtriaOverviewSections.swift:3215`, `:5438`, `:5875` |
| B10 | Today micro-copy with existing destinations: notifications subtitle, calibration rows, add-metrics footer (subset of R22) | `AtriaTodayScreen.swift:1531` (a11y `:1549`), `:4158`/`:4177` (a11y `:4279`), `:3305` |

Near-misses held for batch 2 (still low-risk): R4 settlement-row gating, R12 banner imperatives, R21 strap copy pass, R22 remainder, R17 sync-footer text. Per repo protocol, batch 1 still requires the test-target build + Mirroring visual verification before ship (do-not-ship-blind-UI rule).

---

## 3. Deferred — needs design judgment or visual sign-off

- **D1. Whiteboard range-band bars** — `AtriaTodayScreen.swift:4263` (inputs at `:4150-4177`, a11y `:4279`): replacing "typical X–Y" sentences with a band+dot visual is a new component. Related edge bleed `:4275` can ship earlier (see C7).
- **D2. Daily-brief final composition** — `AtriaTodayScreen.swift:3643/:3636` + `Dashboard.swift:359/380`: which of the three tiers survives is a design call; the calibration-clause relocation itself is mechanical (R5).
- **D3. New sparklines/visuals** — resting-trend tile sparkline `AtriaTodayScreen.swift:2647` (`restingTrend14` at `:33/:65/:1878`); saved-workout banner HR trace `AtriaHomeView.swift:6768` (reusing `AtriaWorkoutSummarySparkline :8567`); strap hero bpm-first + pulse sparkline `AtriaStrapScreen.swift:342` (store passed at `AtriaHomeView.swift:5696`); sync-footer progress capsule `AtriaHomeView.swift:6186`.
- **D4. Notice-band collapse to glyph+chip** — `AtriaHomeView.swift:4861`: only after B3 lands and residual states are inventoried (`:4995`, `:5043` remain honesty copy).
- **D5. Duplicate sleep-confirm surface** — `AtriaOverviewSections.swift:14797` vs `AtriaSleepReviewCard :1240`: product decision on which surface owns Confirm/Adjust; removing interactive controls is beyond a prose pass.
- **D6. Impacts card consolidation** — `AtriaOverviewSections.swift:15446` (keep only the per-tag bar list `:15453-15456`; drop hero/lanes/map `:15450→15575-15586`, `:15595`) + chip row `:15598`: removes three of four representations; needs visual sign-off.
- **D7. planBalanceRail deletion** — `AtriaOverviewSections.swift:8325` (ring `:8253/:8639`, Tonight chip `:8337` vs strip `:8508-8511`): restructures the most-read card.
- **D8. Chart height raises** — HR-load 156→~200pt `AtriaHealthScreen.swift:2924`; stress timeline 184→~230pt `AtriaStressDetailView.swift:634`; stress-by-day 120→~150pt `:1056`; live stress 172→~210pt (R16). All depend on the copy tucks landing first; sign off heights visually.
- **D9. Sleep schedule card restructure** — `AtriaHealthScreen.swift:3133, 3109, 3205` (strings `:3088-3094`, a11y `:3220`): seven prose lines around an 11pt chart; the keep/move split is a design decision.
- **D10. Strap screen de-carding** — `AtriaStrapScreen.swift:80-82` (outer card) + `:264-265/:284-285/:323-325` (hero nesting; host margin `AtriaHomeView.swift:1642`): structural; `:264` depends on `:80`. Plus adaptive grid `:40/:98-101` and the new **Sync tile** (chart finding at `:40`, signals from `AtriaHomeView.swift:5977-6007/:5048` via OfflineSyncDefaults) — display-only but a new surface element; sign off together (C6).
- **D11. daySectionCard flattening** — `AtriaActivityMonitor.swift:2882` (rows `:3095-3096`): removes a container level in a LazyVStack; verify scroll/identity behavior.
- **D12. Workout sheet reorder (charts-first)** — `AtriaActivityMonitor.swift:3859` (lazy trace task `:3968` re-keyed to appearance): interaction-order change.
- **D13. Shared deck gutter / breakout-lane mechanism** — `AtriaHomeView.swift:4585`: one mechanism must be chosen (see C1) before per-surface bleeds R24 stack on it.
- **D14. Detail chart card padding** — `AtriaOverviewSections.swift:11517`: constrained by the Handoff-10 CP3 revert (see C2); only the reduced-padding or plot-background-only variant (weekly precedent `:5692`) may proceed, with visual verification.
- **D15. HR preview trailing bleed via axis move** — `AtriaVitalsCollectionSections.swift:4513` (leading-axis precedent `:4238`): chart re-layout, sign off.
- **D16. Glance-card footer ring/progress dedupe** — `AtriaOverviewSections.swift:6716-6723` vs header ring `:6592-6594→7393-7397`: choose the surviving encoding visually (coordinates with B1/R24 `:6646`, see C8).
- **D17. Backup-cards consolidation** — `AtriaOverviewSections.swift:16250` + `:16219` + `:16339/:16370`: merging two cards is structural.
- **D18. Timeline header value-first** — `AtriaActivityMonitor.swift:2459`; muscular-load statTile treatment `:5038` (grammar from `:4304`); night-arc Window node `AtriaOverviewSections.swift:1278` (hero `:1192`); prior-comparison chip compaction `AtriaTrendChart.swift:241` — each is a small re-composition wanting a visual pass.

---

## 4. Conflicts and overlaps between findings

- **C1. `AtriaHomeView.swift:4585` cited by two surfaces with different mechanisms.** Today proposes per-section -12pt bleed or dropping the shared gutter to 0-4pt for card-backed content; home-overview proposes an opt-in full-bleed breakout-lane modifier (mirroring the already-full-bleed band at `:4599`), keeping 12pt for text cards. These are alternative designs for the same knob — pick one (the opt-in lane is the superset and safer) before any per-surface bleed depends on it.
- **C2. Negative-inset bleed pattern vs the Handoff-10 CP3 revert.** `AtriaOverviewSections.swift:11517` explicitly warns not to reintroduce the reverted negative full-bleed inset on the detail chart card, while sibling findings (`AtriaActivityMonitor.swift:2487`, `AtriaTrendChart.swift:214`, `AtriaHealthScreen.swift:2924`, `AtriaVitalsCollectionSections.swift:6653`, `:5201`) propose exactly that pattern on other cards. Not a direct contradiction (different cards), but it proves the pattern has failed once on this codebase — bleed per-card with visual verification, never as a blanket modifier.
- **C3. "HR-only" literal token dependency.** `AtriaStressMonitor.swift:4109`'s proposed copy notes `AtriaHomeView.swift:4715` substring-matches "HR-only" in the detail string. This constrains every edit to that shared string chain: `AtriaStressDetailView.swift:581`, `:426`, `:883`, `:667`. All batch-1 dedupes there remove *renders*, not the source string; the source shorten (4109/581) is batch 2 with the token preserved.
- **C4. Sleep-review duplication described from both sides.** `AtriaOverviewSections.swift:1140` (review-card subtitle) and `:14797` (journal duplicate confirm block) touch the same flow; shorten `:1140` freely, but `:14797` needs the D5 product decision first so the two edits don't strand the flow.
- **C5. `AtriaHealthScreen.swift:2924` appears in both edge findings (bleed) and chart findings (height raise).** Complementary, but the height raise is explicitly sequenced *after* the copy relocations at `:2951/:2809/:2938` (B4).
- **C6. `AtriaStrapScreen.swift:40` cited by both an edge finding (adaptive grid) and a chart finding (new Sync tile).** Same grid; implement together in D10 to avoid churn, and note the Sync tile must carry terminal-parked interval truth visibly per the honesty rule.
- **C7. Whiteboard: edge `AtriaTodayScreen.swift:4275` (bleed) vs chart `:4263` (band bar).** Both cure the same 0.6-scale text shrinking. If the band bar (D1) ships, the bleed's motivation partly disappears — ship the bleed first (cheap), re-evaluate D1 against the widened rows.
- **C8. Tall glance card footer touched three times.** `:6731` (text dup, B1), `:6716` (ring/progress dup, D16), `:6646` (padding + sparkline widening, R24). B1 is independent; D16 and the `:6646` sparkline widening should land together.
- **C9. Stress hero region touched by three findings.** `:581` (shorten), `:903` (legend tuck), and chart `:634` (grow timeline) — `:634` depends on both copy items landing.
- **C10. Saved-workout banner deletions feed a deferred visual.** `:6723` + `:6830` deletions (R18) create the space the D3 sparkline (`:6768`) proposes to use; the deletions can ship first.
- **C11. Retention-policy sentence duplicated across two states.** `AtriaActivityMonitor.swift:955` and `:989` get the identical proposed string ("Outside the 2-day detailed-history window") — change together for consistency.
- **C12. Notice band chain.** `:4924`/`:4615` (B3) → residual states `:4995`/`:5043` (shorten, batch 2, honesty accessories required) → `:4861` collapse (D4). Three findings, one band, strict ordering.
- **C13. Sleep chip region touched twice on Today.** `:1738` (chip caption shorten) and `:2206` (percent-of-need dedupe via the `:1046` `suppressesDetail` extension) both edit the chip detail text path — do in one edit.
- **C14. Gutter changes stack.** R15/R24 internal-padding reductions and the C1 deck-gutter decision both widen content; land R15 (fixed numbers) before the C1 mechanism so widths shift once, not twice.

---

## Do-not-touch guardrails (audited `keep` findings)

`AtriaTodayScreen.swift:2539` (sleep-efficiency blockers); `AtriaHomeView.swift:6334-6335` (terminal data-loss truth); `AtriaOverviewSections.swift:7566` ("Estimated · HR-only" hypnogram marker, pinned by comment `:7563-7565`) and `:15489` (correlation-not-causation); `AtriaHealthScreen.swift:1473` (SpO2 "Not available on this strap" — direct user request); `AtriaVitalsCollectionSections.swift:3766` (handoff-12 CP3 compact provenance line — the model, not a target); `AtriaStressMonitor.swift:245` (single-line unscored blockers); `AtriaStrapScreen.swift:27` (export status line is a live progress channel).
