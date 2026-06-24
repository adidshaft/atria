# Codex Handoff — UI consistency, de-duplication, and "less text / more visual"

Date: 2026-06-24
Skill to apply: `~/.codex/skills/liq-glass/SKILL.md` (Code Prism Liquid Glass).
Use its first principles throughout: **glass for interactive controls, calm
grouped surfaces for content; titles readable before body truncates; standard
components (segmented picker, `Menu`, `.buttonStyle(.glass/.glassProminent)`);
preserve contrast under reduce-transparency.**

This is the iterative, screenshot-driven pass. The connected state can only be
seen on the cabled iPhone, so verify each change there. Build/verify constants +
debug launch args are in `docs/15` and `docs/16`; useful QA args already exist:
`--whoop-force-coexistence-risk <suspected|advisory|cleared>`,
`--whoop-force-offline-sync`, `--atria-developer-mode --whoop-complete-onboarding`.

## North-star rules for this pass
1. **One fact, one place.** A score/metric/status appears exactly once per screen.
2. **Words are a last resort.** Replace status sentences with a colored dot, icon,
   ring fill, or chip. Cap any supporting line at ~6 words.
3. **Standardize tokens.** All cards use `AtriaDesignTokens.Radius.card` (one
   radius), one padding scale, one tint ramp. No ad-hoc 22/24/26/30 mix.
4. **State as visual, not text.** "Learning" / "local" / "contact reacquired" /
   "personal baseline" must become a visual state (muted/dashed ring, small
   `seal`/`waveform` glyph, color), with the word available only via tap/accessibility.

## Already done (don't redo — verify on device)
- Connected hero is now just the live-pulse card; the duplicate Recovery/Strain/
  HRV row + verbose headline + inline "Today" chip were removed (`HEAD`).
- Single toolbar connection chip (color-by-state, "Live"/"Disconnected"); removed
  the bolt button + strip chip.
- Removed the "Quick actions" card (duplicated the tab bar).
- WHOOP coexistence is a modal (suspected-only).
- Glance shows on disconnected too (saved data) + resting-HR sparkline (Codex).
- `AtriaPanelSectionHeader` now hides empty subtitles.

## Concrete issues found in the connected screenshot (fix these)
Reference: `logs/live-device/screenshots/unlocked-retry-20260624T165213Z.png`.

1. **"Today at a glance" is text-heavy and states repeat.** Recovery shows
   "Learning" as big text + "learning" subtitle; HRV shows "Learning" + "contact
   reacquired"; Strain shows "0.0" + "local". → Show the *number* prominently and
   render the state as **visual**: a dashed/greyed ring for "learning", a tiny
   `checkmark.seal` when validated, a contact glyph when contact is lost. Drop the
   word-subtitles; keep at most a one-word chip.
2. **Live-pulse card** ("Live pulse / WHOOP strap / 77 bpm") — make the **77 the
   hero element** (large, monospaced) with a small heart glyph; "WHOOP strap" and
   "Live pulse" are redundant with the toolbar Live pill — drop one.
3. **Bottom live accessory** shows transport/media controls (rewind/play/forward)
   next to "Live strain 0.0 … 5%". Audit: if these are media controls they look
   out of place on a fitness live bar — either move media to a dedicated control
   or replace with a compact live HR + battery. Don't show two strain values
   (accessory + glance).
4. **"2 of 3 ready"** footer is cryptic — either make it a 3-dot progress glyph
   with an accessibility label, or remove.
5. **Card geometry is inconsistent** — radii seen: 17, 22, 24, 26, 30. Collapse to
   the two `AtriaDesignTokens.Radius` values (card/inset). Same for padding.

## Per-surface TODO
- **Today (connected)**: glance is the single scores card (ring + Strain/HRV/Sleep
  + sparkline). Hero = live HR only. Checklist/guidance below. No metric repeats.
- **Today (disconnected)**: connection strip (reassurance, no status word — the
  toolbar chip owns status) + saved glance + trends. Audit the
  `AtriaDisconnectedOverviewPanel` for leftover wordy cards (automatic-setup,
  checklist) — convert step lists to compact numbered glyph rows, ≤6 words each.
- **Vitals**: cards (`AtriaPulseCard`, `AtriaHRVCard`, `AtriaRecoveryStrainCard`,
  `AtriaProfileCard`) — make each a big value + small label + state glyph; strip
  the explanatory paragraphs (move long help into an `info` `Menu`/popover).
  Convert remaining stat `ViewThatFits` → adaptive `LazyVGrid`.
- **Data/Collection**: the most text-dense tab. Lead with the primary action
  (Export / Sync) as glass buttons; demote capture/diagnostic copy behind a
  disclosure. Reuse the same stat-tile component as Today.
- **Settings**: already a clean grouped `Form`; just ensure footers are ≤1 line
  and icons are consistent.
- **Onboarding**: keep minimal; ensure step bodies are ≤2 lines.

## Consistency primitives to introduce (reduces text + duplication at the root)
- A single **`AtriaMetricTile`** (value + label + optional state glyph + optional
  sparkline) used by the glance, Vitals, and Data so a metric looks identical
  everywhere. Kills per-card bespoke layouts and copy.
- A single **`AtriaStateBadge`** that maps a metric state
  (`learning|personalBaseline|validated|noContact`) to **icon+color only** (word
  in accessibilityLabel). Replace every inline "Learning"/"local"/"contact
  reacquired" string with it.
- Route long explanations through one **info popover** pattern (`Menu`/`.popover`
  with an `info.circle`), never inline paragraphs in content cards.

## Verification (device)
For each screen: install (`live_device_debug.sh … --leave-running`), foreground
Atria with the strap on, capture a screenshot, and confirm: (a) each metric
appears once, (b) no content card has more than a title + value + ≤6-word line,
(c) all cards share radius/padding, (d) states read as color/icon not words.
Keep `python3 test_handoff_static_checks.py` green (33) and respect the
local-first/no-`https://` guard.
