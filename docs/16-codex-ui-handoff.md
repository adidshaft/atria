# Codex Handoff — UI refinements (connected-state + device verification)

Date: 2026-06-24
Author: Claude (simulator-verified what it could; connected surfaces need device)

Context: a batch of home-screen UI fixes just landed on `main`. The pieces below
either render only in the **connected** state (no BLE in the Simulator) or need a
worn-strap/device check, so they're handed to you with the device.

## Already landed + simulator-verified (just confirm on device, don't redo)
- **Single connection status** — toolbar chip (color-by-state, readable text,
  taps to scan) replaces the old 3+ indicators. Removed the toolbar bolt button
  and the strip's status chip. (`9f97ab2`)
- **Removed "Quick actions" card** (it duplicated the Today/Vitals/Data tab bar).
- **WHOOP coexistence is now a modal** (`AtriaWhoopCoexistenceModal`), shown only
  when `officialWhoopCoexistenceRisk == .suspected` (snoozes 1h on acknowledge),
  not a permanent inline card.
- **Lag fixes**: removed per-element `.glassEffect` chrome → translucent fills
  (`13e3671`); removed backdrop `.blur` → radial gradients; converted 4
  `ViewThatFits` stat blocks → single adaptive `LazyVGrid` (renders once).
- **Segmented Today** (Today/Trends/Data), **trend 7/30/90-day range selector**,
  **Export to Apple Health**, **Sync missed data from strap**, **at-a-glance
  recovery ring**.

Build/verify constants are in `docs/15-codex-realtime-ble-validation.md`
(device id `3803F5B6-…`, bundle `com.adidshaft.atria`, harness invocation).

## TODO 1 — "Quick glance" needs scores + a graph (user's words)
The at-a-glance card (`AtriaOverviewReadinessSection` in `AtriaOverviewSections.swift`)
already shows a Recovery ring + Strain / HRV / Sleep / Resting stats, **but**:
1. It renders **only in the connected overview** — when disconnected the user sees
   no glance at all (just the connection strip). **Surface a glance with the
   last-known/saved scores even when disconnected** (the data is local; read from
   `store`/`snapshotStore`). The disconnected host is
   `AtriaDisconnectedOverviewHost`; thread the hero/snapshot or a saved-score
   summary in and show a read-only glance above the trend chart.
2. **Add a small graph** to the glance — a sparkline of the last ~14 days of the
   primary metric (recovery or resting HR), so it reads at a glance. Reuse
   `AtriaTrendPoint`/Swift Charts (see `AtriaTrendChart.swift`) at a compact
   height (~60pt, no axes), or the existing `Sparkline` shape in `ContentView.swift`.
Verify on device (connected) that recovery/strain/HRV/sleep populate and the
sparkline draws.

## TODO 2 — finish the perf pass (remaining ViewThatFits)
11 `ViewThatFits` remain in `AtriaVitalsCollectionSections.swift` (stat rows +
button rows). Convert the **stat** ones (`HStack { stats } / LazyVGrid { stats }`)
to a single `LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)])`
like the Overview ones — each `ViewThatFits` renders both candidate layouts to
measure, doubling per-card cost. Leave the HStack-vs-VStack **button** ones.
These are in the Vitals/Data tabs (connected-state) — verify they still lay out.

## TODO 3 — verify connected-state surfaces on device
The Simulator has no BLE, so these were compile-verified only:
- Segmented Today (Today/Trends/Data) renders + the segment control sits well.
- The glance recovery ring fills with real recovery %, color-graded.
- The status chip turns **green "Live"** when connected.
- The coexistence modal actually triggers when WHOOP interference is detected
  (force a connect-failure with WHOOP installed, or temporarily set
  `officialWhoopCoexistenceRisk = .suspected`), and snooze works.
- `Export to Apple Health` and `Sync missed data from strap` (Settings → Your
  data) run and report status (pull `whoop.offlineSync.*` to confirm the sync
  actually probed + cleared `rangeLossBackfillPending`).

## TODO 4 — auto-detect missed data + surface on home (carry-over)
The manual "Sync missed data" button exists, but the user wants **automatic
detection**: when `whoop.offlineSync.rangeLossBackfillPending == true` (or the
strap clearly has data Atria lacks), show a dismissible home banner ("New data on
your strap — Sync") that triggers the same `requestOfflineHistoricalSyncIfNeeded(force:true)`.
Expose `rangeLossBackfillPending` as a `@Published` on `WhoopBLEManager` and gate
the banner on it. Keep it out of the way during live viewing (the sync steals the
live link ~180s — see `docs/14` §0b and the `deferred_live_link` logic).

## Guardrails
- Keep `python3 test_handoff_static_checks.py` green (iOS-26 patterns, honesty
  copy, local-first no-network, standard-HR-only write guard).
- No `https://`/network clients in the app core (the local-first test forbids it).
- Build to the Simulator for compile/layout, the device for BLE/connected truth.
