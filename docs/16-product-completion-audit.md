# Atria product completion audit — 2026-07-12

This is the evidence ledger for the active “WHOOP-replacement” objective. A green
build is not treated as product completion. A requirement is complete only when
source behavior, automated coverage, and physical-device evidence agree.

## Proven in the current Release

- User-started workouts survive sparse or absent HR, process relaunch, and an
  atomic activity edit. Strength sets and paused intervals remain attached.
- A single HR spike cannot create an automatic workout. Detection requires
  sustained, recent, contact-valid evidence and continuous coverage.
- Unexpected BLE reconnects no longer create a new saved session for every
  short disconnect. A physical app-switch interval accepted 72 samples while
  backgrounded and created no new session fragment.
- The lock-screen Live Activity carries live HR, HR zone, elapsed time, strain,
  steps (explicitly marked as an estimate while unvalidated), pause/resume, and
  stale-signal state.
- Activity editing commits label, type, and time in one `Save`. Activity-specific
  symbols are used in history, maps, Live Activity, and sharing.
- Outdoor workout routes support background collection, pause boundaries,
  accurate pace coverage start, activity-aware GPS rejection, edit
  reconciliation, and explicit GPX sharing. Image sharing does not silently
  disclose exact coordinates.
- HRV normal-wear recomputation is cadence-gated; fitness age uses a weekly
  asynchronous cache. Recovery remains visibly provisional until baseline
  evidence matures.
- Battery UI is intended to fail closed to `Pending` until a fresh GATT value
  arrives. Field reports of transient false 0%/100% and a stale 10% projection
  mean this remains under active correction; it is not a completed gate.
- Sleep-stage fallback work is range-bounded and allocation-light rather than
  rescanning the complete sample array for every epoch.
- Live route geometry is capped at 512 coordinates while full-fidelity points
  remain available for recovery/export. Checkpoints append new fixes to a
  journal and atomically rewrite only bounded metadata.
- A corrupt middle active-session segment can be bridged by the next valid
  segment through verified redundant overlap; mismatched chains fail closed.
- HR/RR-only sustained effort is a review candidate, never a counted workout,
  until the user confirms its context. The live gate measures elapsed time,
  rejects duplicate/backwards timestamps, and expires stale evidence.
- A fresh accepted pulse overrides a lagging service-discovery projection, so
  the header cannot say `Waiting` while a live BPM is being rendered.
- Native phone motion now acts as conservative context: fresh medium/high
  automotive evidence suppresses an automatic workout prompt; walk/run/cycle
  suggestions require two sustained minutes; uncertain, stale, stationary,
  and Dance contexts abstain.
- SpO2 and skin-temperature surfaces share production-decoder gates. Cached or
  fixture-derived candidate values cannot escape into cards, details, zones,
  accessibility copy, targets, or Release aggregation.
- The Activity title and Add action share one row; its redundant 24-hour axis
  remains hidden while exact activity times stay in the editable rows.
- Vitals Health Monitor uses compact two-column metric grids, falls back to one
  column at accessibility Dynamic Type sizes, and keeps Stress full-width.
- Workout sharing now includes a self-contained HTML recap that opens without
  Atria and contains no coordinates. Exact GPX remains a separate opt-in.
- Core Motion refreshes are publisher-observed without making the whole Home
  shell observe the monitor, preventing a 30-second broad invalidation cycle.

## Final Release verification — 2026-07-12 05:15 IST

- 705/705 Swift tests passed and 174/174 static checks passed.
- The warning-free signed Release installed as `com.adidshaft.atria`; executable
  SHA-256: `d9365f1aaddac2dda35491bdc1b9a2b975d6fffdc971e991da8b498378e9bdba`.
- Physical pull after install showed `connected`, fresh `live_2A19` battery 10%,
  and a 2.9-second-old accepted strap packet.
- Over the following 20 seconds, accepted samples increased 226,068 → 226,110
  while saved sessions stayed 438 and confirmed workouts stayed 8. Continuous
  wear therefore did not fabricate a workout or a disconnect fragment.
- Evidence: `evidence/final-round3-release-20260712-0514` and
  `evidence/final-round3-release-followup-20260712-0515`.

## Motion-context Release verification — 2026-07-12 05:33 IST

- 714/714 Swift tests passed and 174/174 static checks passed.
- The warning-free signed Release installed as `com.adidshaft.atria`; executable
  SHA-256: `88fc399100bb915220fd229eed303c7d58d96fb1518b6c587eae1e4aa904276d`.
- The pre-install snapshot preserved 439 sessions, 8 confirmed workouts, and a
  fresh direct GATT battery value of 39%.
- After install, the physical pull showed `connected`; accepted strap samples
  increased 227,222 → 227,287 while sessions stayed 439 and confirmed workouts
  stayed 8. No incidental prompt was promoted into a workout.
- Evidence: the latest `evidence/pre-motion-context-install-*` directory and
  `evidence/post-motion-context-install-20260712-0533`.

## Sharing, motion-audit, and Vitals Release — 2026-07-12 05:55 IST

- 720/720 Swift tests passed and 174/174 static checks passed.
- The warning-free signed Release installed as `com.adidshaft.atria`; executable
  SHA-256: `71db448613f5b518bfa79aa91210a70b9bf43e1d35bc4d719e5cf0f810d62283`.
- The first launch attempt coincided with a transient SpringBoard XPC restart;
  the retry launched successfully and Atria remained running.
- Accepted samples increased 227,676 → 227,844 while sessions stayed 440 and
  confirmed workouts stayed 8. Direct battery evidence remained 39%.
- The foreground motion monitor did not start while the device scene remained
  inactive; the pull therefore reports `no_snapshot`, with the effective gate
  forced to `abstain`. Missing motion context cannot veto or label a workout.
- Evidence: `evidence/post-share-motion-ui-final-20260712-0552` and
  `evidence/post-share-motion-ui-effective-20260712-0555`.

## Lossless session recovery — 2026-07-12 06:22 IST

- A launch migration was found deleting every sub-five-minute `Auto-saved`
  fragment without proving duplicate coverage. It removed 320 sessions with
  5,635 unique HR points and 3,010 unique RR points. The historical archive did
  not contain metric-usable replacements for that evidence.
- The destructive launch migration was removed and a static regression now
  rejects its function and persistence operation. The integrated suite passed
  727/727 Swift tests and 174/174 static checks before the recovery build.
- A warning-free signed Release was installed first, then the preserved
  pre-migration `sessions.json` was restored into Atria's own container. The
  on-device file matched the source byte-for-byte and contained 441 sessions.
- A normal post-recovery launch succeeded. A fresh non-disruptive pull still
  contained 441 sessions and all 8 confirmed workouts, proving the corrected
  launch is non-destructive.
- Executable SHA-256:
  `381b82b80f1cf4b645adc0fdee218bfef7175e3daa32dbeaa01395dc41e98ea6`.
- Evidence: `evidence/pre-atomic-density-install-20260712-0611` and
  `evidence/post-lossless-restore-launch-20260712-0622`.

## Battery and workout-classification correction — 2026-07-12 06:29 IST

- Live evidence showed a 10% battery value still labelled usable more than 15
  minutes after its last accepted 2A19 response, despite the HR stream also
  being stale. Atria now polls retained battery characteristics every two
  minutes and fails closed to `Pending` after ten minutes without an accepted
  battery response.
- Restoration-boundary 0%, 10%, and 100% values require a stable series before
  display; ordinary midrange readings such as the owner's verified 43% can
  corroborate quickly. Confirmation reads are bounded rather than recursively
  issuing a tight GATT loop.
- Saved HR-only sustained effort now remains an `activityCandidate` with
  “Effort ready to review” copy. It cannot claim “Workout found” or infer a
  type without time-aligned motion context or explicit user confirmation.
- The focused battery, false-workout, and lossless-restore suite passed 41/41.
  The full integrated suite and physical post-install battery series remain the
  next Release gate.
- Evidence: `evidence/pre-battery-fix-live-20260712-0627`.

## Integrated durability/battery/classification Release — 2026-07-12 06:36 IST

- 730/730 Swift tests passed and 174/174 static checks passed. The signed
  Release build was warning-free; executable SHA-256:
  `f2335d29de0297d5e0a589e1214e5c051e5abfa48ba2b0313a36af370051ae6e`.
- The Release installed as `com.adidshaft.atria`. Its automatic launch was
  denied because iOS reported the physical phone locked; no password or unlock
  workflow was attempted.
- The locked post-install pull preserved the restored session store byte-for-
  byte: 441 sessions, 8 confirmed workouts, SHA-256
  `c0d6aa9ba0db6bd72c370c81b0ff34d22af09c7ec0494c92ae48d2fe9afb6fc1`.
- The diagnostic pull now applies the same ten-minute battery freshness
  contract as the app. The 24-minute-old persisted 10% reading correctly
  reports `battery_effective_status=pending` and no effective percentage.
- Evidence: `evidence/post-integrated-install-locked-effective-20260712-0636`.

## App-switch, workout durability, and density Release — 2026-07-12 06:47 IST

- Transient `.inactive` transitions no longer synchronously encode BLE/session
  diagnostics, stop Core Motion, or rebuild a healthy workout radio pipeline.
  Checkpointing is cancellably deferred; a true background edge remains the
  durable boundary.
- A true background transition now checkpoints workout type, sets, an open
  pause, pending intent, RR-only progress, sensor journal, and route. Explicit
  workouts remain journal-eligible even when all-day wear is disabled.
- Fast launch no longer synchronously rereads and merges the multi-megabyte
  session store and latest backup on the main actor. Deferred load and pre-load
  upsert reconciliation retain the existing lossless guarantees.
- Settings explanatory rows now collapse natively; Today/Plan and Journal omit
  repeated visible rationale while retaining it for VoiceOver. Live workout
  target commit uses `Save`; its non-committing set sheet uses `Close`.
- 741/741 Swift tests and 174/174 static checks passed. The warning-free signed
  Release installed with executable SHA-256
  `26be4df6b121d34be1f3e69653ad416bdddd5e98324554d13eeb8b3080867355`.
- Locked post-install verification preserved the recovered store byte-for-byte:
  441 sessions, 8 confirmed workouts, and battery effective state `pending`.
- Evidence: `evidence/post-resume-density-install-locked-20260712-0647`.

## Missing-workout historical recovery Release — 2026-07-12 07:03 IST

- The July 11 Strength workout is present, but its saved sensor evidence is
  objectively incomplete: 58 samples across 50 minutes, 3% HR coverage, and
  87.1 seconds observed. The historical archive ends before that workout
  window, so its prior 0.174 strain was an incomplete-data result rather than
  evidence that no workout occurred.
- Atria no longer clears range-loss recovery merely because some older archive
  data is metric-ready. A sparse confirmed workout persists its exact missing
  start/end window and requests historical recovery for that interval. The
  07:03 Release still treated one newly appended timestamp inside that window
  as acknowledgement; the coverage-aware correction below closes that remaining
  false-success path.
- When real metric-usable archive samples arrive, the existing confirmed
  workout is rehydrated in place. The merge deduplicates absolute timestamps,
  excludes saved pauses, requires strictly better coverage without fewer
  samples, and preserves the workout ID, time, label, type, exercises, sets,
  pauses, review state, and time-zone metadata.
- Workouts below 25% coverage now show `Incomplete` for derived strain, average
  HR, calories, zones, and share metrics. Recorded type, exact time, duration,
  peak HR, and editing remain available; Atria does not fabricate missing
  telemetry.
- 748/748 Swift tests and 174/174 static checks passed. The signed Release build
  was warning-free and installed successfully with executable SHA-256
  `ca76842b60673bf49e55855a5b0bf8ee5bd09ba9fb876191f1ce4fed1111f073`.
- The locked post-install pull preserved 441 sessions byte-for-byte (SHA-256
  `c0d6aa9ba0db6bd72c370c81b0ff34d22af09c7ec0494c92ae48d2fe9afb6fc1`)
  and all 8 confirmed workouts. iOS denied the post-install app launch because
  the phone was locked, so the new exact-window request and live historical
  retrieval remain pending until the next unlocked launch.
- Evidence: `evidence/final-recovery-install-20260712-0703`.

## Coverage-aware exact-window recovery correction — source verified

- An audit found that one overlapping historical frame could clear an exact
  workout request even when the frame was diagnostic-only, or when the rebuilt
  workout remained far below useful coverage. That was weaker than the metric
  rehydration contract and could strand the July 11 Strength workout as
  `Incomplete` after apparent recovery success.
- Overlapping frames now count only as progress when they are metric-usable.
  Progress never clears an exact workout request by itself. The durable request
  resolves only after the matching saved workout is atomically rehydrated to at
  least 75% stream coverage. A 74% rebuild and a different workout both leave
  it pending. Ordinary non-window disconnect recovery retains its existing
  fresh-row acknowledgement behavior.
- The focused recovery and workout-durability suites passed 59/59 on the iOS
  simulator. Static checks and physical Release installation remain part of the
  integrated gate; this source correction is not attributed to the installed
  07:03 Release.

## Physical backlog and full-sensor correction — 2026-07-12 07:26 IST

- The original production recovery preflight (abort + high-frequency sync +
  history request) completed a physical 180-second attempt with zero appended
  rows. Production now uses the stable WHOOP 4 sequence: one acknowledged
  `SEND_HISTORICAL_DATA` (`0x16`, payload `00`) request on the settled link.
  Debug range/selector probes remain isolated from this path.
- The corrected physical request appended 1,240 archive rows. This proves the
  transport correction works. The resulting archive still contains zero rows
  and zero metric-usable rows in the July 11 Strength interval. Its first newly
  timestamped post-gap row begins at unix `1783775595`, about 66 minutes after
  the workout ended at `1783771620`; the saved workout therefore remains
  truthfully `Incomplete` rather than receiving invented strain.
- Exact-window recovery remains pending until that same workout reaches at
  least 75% real HR coverage. The successful unrelated backlog cannot clear it.
- An on-device preference audit found `standardHROnly=true` with no
  `standardHROnlyUserSelected` flag—the residue of the removed automatic sync
  downgrade. Launch migration now repairs this legacy-only state to full
  protocol so R10 motion/steps resume; an explicit Battery Saver choice remains
  authoritative.
- Add/Edit activity-type controls now show the same per-type SF Symbol used by
  timelines, workout cards, sharing, and Live Activity.
- 754/754 Swift tests and 174/174 static checks passed. The warning-free signed
  Release installed successfully with executable SHA-256
  `ea11b264f40489c0c5c9e96fac1c0afe89d08c27c99ea72dc4b6f3f7765ff249`.
  iOS locked before the post-install launch, so the legacy radio migration and
  renewed live R10 stream require the next unlocked Atria launch.
- Physical evidence:
  `evidence/plain-history-attempt-pre-radio-repair-20260712-0722` and
  `evidence/final-full-sensor-install-locked-20260712-0726`. The locked pull
  retains all 8 confirmed workouts and 443 durable session/checkpoint records.

## R10, Lock Screen action, and foreground-latency Release — 2026-07-12 07:40 IST

- R10 recovery now requires a frame received after the current arm epoch;
  pre-arm, stale, and future-dated frames cannot falsely declare the stream
  healthy. Two bounded command reassertions escalate to full-protocol service
  rediscovery, rate-limited to once per minute. Detector thresholds are
  unchanged.
- Live Activity actions use a bounded 16-command queue rather than one
  overwriteable value. Pause, Resume, and End execute in issued order after a
  delayed app wake, and workout confirmation, pending intent, pause accounting,
  and route finalization share the exact clamped tap timestamp.
- Foreground sleep settlement no longer rebuilds/sorts the lifetime canonical
  archive on the main actor. Its interactive path uses newest-first seven-day
  evidence capped at 512 sessions and losslessly replaces the matching active
  journal; background/full diagnostics remain unchanged.
- Physical pull diagnostics now expose radio mode, explicit Battery Saver
  ownership, full-protocol migration state, and whether legacy automatic repair
  is required. Locked evidence confirms the pending migration is legacy-only:
  `standard_hr_only=1`, `user_selected=0`, `repair_needed=1`.
- 758/758 Swift tests and 174/174 static checks passed. The warning-free signed
  Release installed successfully with executable SHA-256
  `5657170967453a4e00fcbf479dd480b355a45bdac7fa4fce96509fc42a10bdef`.
  iOS again denied launch because the device was locked, so physical R10/live
  step verification remains gated on an unlocked Atria launch.
- Evidence: `evidence/locked-radio-policy-audit-20260712-0730`.

## Wrist-only motion boundary — 2026-07-12 08:21 IST

- Atria contains no `CMPedometer` path. Phone `CMMotionActivityManager` is a
  fresh, conservative context gate only: automotive can veto a false prompt,
  sustained Walk/Run/Cycle can suggest a label, and denied/stale/ambiguous
  permission always abstains. It cannot create steps, HR, strain, or a workout.
- The unlocked physical launch repaired the durable radio state exactly as
  intended: `standard_hr_only=0`, `user_selected=0`,
  `strap_step_full_protocol_migrated=1`, runtime/effective mode
  `full_protocol`, live battery 35%, and a connected live strap stream.
- Physical R10 capture continued after launch: the bounded archive reached
  12,511 CRC-valid packet-type `2b` / record-type `0a` rows, with the latest
  frame at `2026-07-12T02:52:15.173Z`. The source is wrist R10 IMU; phone step
  fallback remains zero.
- Calibration/full-protocol overrides now remember Battery Saver only when the
  user explicitly selected it. A legacy automatic saver value cannot be
  restored when calibration expires.
- 758/758 Swift tests and 174/174 static checks passed. The warning-free signed
  Release installed and launched successfully with executable SHA-256
  `2e7872597291e27df7619ba1f99d6ae85003803948533f5eb73e9c71cb186fc0`.
- Evidence: `evidence/post-calibration-radio-repair-20260712-0821` and
  `evidence/wrist-only-boundary-20260712-0823`.

## Permission fallback, density, battery, and physical workout pass — 2026-07-12 08:50 IST

- Denying or restricting Motion & Fitness now settles immediately to an
  `unknown`/abstain context and stops Core Motion updates and history polling.
  It cannot veto a workout, invent an activity type, or affect wrist R10 steps,
  HR, strain, sleep, or manual workouts. The obsolete inert phone-step
  lifecycle hook was removed; `CMPedometer` remains absent from Atria.
- Protected long-wear production intentionally does not discover or read the
  independent 2A19 battery characteristic: physical A/B showed that doing so
  destabilized the HR link. A recent credible value remains visible for at most
  ten minutes, then every surface shows Pending. Full-protocol research modes
  retain bounded refresh and quarantine for 0/10/100 restoration sentinels.
- Activity now combines day navigation and Add into one compact toolbar,
  removes the duplicate section heading and x-axis labels, and reduces the
  empty timeline height. Onboarding removes duplicated visible connection copy
  while retaining the full guidance in its accessibility label.
- The supplied design archive was mapped against Healthspan, Stress, and
  Breathwork. Healthspan already uses the cached weekly age model and a
  transform-only, Reduce Motion-aware orb; Stress retains gap-preserving real
  evidence rather than invented typical-day/stressor claims. Breathwork now
  uses one live `Relax · m:ss` header, one compact progress/HR rail, and a
  smaller native-Liquid-Glass animated orb without the duplicate large timer.
- The prior counted walks were replayed using both the saved exact workout
  timestamps and the reported minute windows. All eight interpretations have
  zero R10 frames because the retained stream has a hard 13:14:44–16:13:09 IST
  gap. The 16:47–17:37 Strength window contains only six isolated frames
  (0.2% coverage). Detector promotion remains correctly rejected and `~`
  stays visible; no repeat walk was requested in this pass.
- July 11 strain was independently replayed from all 74 canonical sessions:
  TRIMP `43.1738420523` maps exactly to saved strain `3.33072828615`. Confirmed
  workout metadata is not added to TRIMP, there are no overlapping canonical
  session pairs or cross-session duplicate timestamps, and saved/live merging
  remains monotonic. The low value reflects 10% Main Walk and 3% Strength HR
  coverage; bridging separate-session gaps would invent 18.1 minutes and only
  raise strain to approximately 3.66.
- A physical production workout verified start, durable segmented journal,
  background sample growth (157 to 179), Dynamic Island live HR, foreground
  restoration, and an exact 25.894-second Pause/Resume exclusion. After
  Mirroring reconnected, End completed through the production UI. The pending
  intent cleared and the ninth confirmed workout saved with 350 samples, 100%
  stream coverage, average HR 78, peak HR 101, and the exact pause exclusion.
- 770/770 Swift tests, 174/174 static checks, 5/5 sensor-reference tests, and
  6/6 step-coverage tests pass. The signed warning-free 37 MB Release build has
  executable SHA-256
  `48ec76d39607cb552d2799882edfa2364fb3672ab7eab7d502c48e40facb7a89`.
  That Release was installed after the workout save without losing any of the
  nine confirmed workouts.
- The installed Activity screen keeps the compact day/Add toolbar, shows the
  14-minute workout with a visible chart marker, and removes recovery repetition
  from the summary row. Route-file I/O now happens asynchronously after sheet
  presentation rather than blocking the editor initializer.
- Today and Vitals now present Breathwork through narrow live-pulse observers,
  so HR/RR continue changing after launch. Reduce Motion uses a one-second clock
  rather than rebuilding the orb and glass subtree at 30 fps. Onboarding BLE
  observation and minimized-workout strain are likewise isolated to small live
  leaves instead of invalidating their full parent screens.
- At a glance now supports persisted stable-key drag/drop from Customize Today,
  including native move handles and VoiceOver Move Up/Down actions. Overview's
  full hero collapses into a viewport-pinned compact rail containing the same
  three configured icons, values, and miniature rings. Settings opens as five
  plain-language collapsed groups: Personal, Strap, Alerts, Data, and Privacy
  & About.
- The ring-image launcher uses standard compact controls and routes back into
  Atria's shared full 1080x1920 composer. The complete 9:16 preview fits without
  cropping; accent canvases, Photo, Camera, and Clear remain available, with
  only Download at upper left and Share at upper right.
- The Today launcher now uses an explicit circular Share control beside the
  circular overflow menu. The composer includes four optimized original picture
  canvases (abstract pulse, alpine dawn, neon run, and anime-inspired ascent),
  and the selected picture fills the actual 9:16 card preview and exported PNG
  behind the ring and metrics rather than appearing as an inset mockup.
- Final physical smoke evidence shows live HR, full strap protocol, nine saved
  workouts, `strap_r10_imu` steps with no phone fallback, and battery `Pending`:
  the persisted 35% sample is more than an hour old and therefore correctly
  withheld instead of appearing as a current 0%, 35%, or 100% value.
- Evidence: `evidence/continuation-device-audit-20260712-083220` and
  `evidence/physical-workout-lifecycle-{before,active,background,paused,resumed,ended}-20260712-*`,
  `evidence/physical-workout-lifecycle-final-20260712-085256`, and
  `evidence/final8-post-install-20260712-0919`, and
  `evidence/final10-ui-post-install-20260712-1016`, and
  `evidence/final-share-backgrounds-20260712-1037`.

## Sleep-to-sleep cycle consistency Release — 2026-07-13 04:45 IST

- Home, widget, notifications, HR-zone summaries, strain, active calories, and
  live-workout deltas now use the same physiological boundary: the latest main
  sleep wake, with naps ignored and a deterministic learned no-sleep fallback.
- Adding, editing, or deleting confirmed sleep invalidates the cycle aggregate,
  TRIMP, and HR-zone caches. Active sessions that cross a boundary clip their
  pre-boundary HR, calories, and steps rather than leaking them into the new
  cycle. No-main-sleep recovery remains an explicit unverified 1%, never a
  fabricated normal score.
- The focused physiological-cycle suite passed 9/9, including shift-worker
  daytime sleep, nap non-reset, all-nighter rollover, sleep edit/delete, and
  cross-boundary live session cases. Static checks passed 176/176.
- The signed Release installed and launched as `com.adidshaft.atria`. Physical
  counters advanced by 81 accepted HR samples and 83 CRC-valid R10 frames with
  zero new disconnects. The legacy `standardHROnly` preference name describes
  the protected 2A37-plus-stream-5 mode here; diagnostics now report the
  effective mode as `protected_hr_plus_r10` instead of falsely requesting a
  migration repair.
- The later 10:52–10:57 counted calibration session was recovered but contains
  only 20 valid R10 seconds across 300 seconds (6.7% coverage, 16 continuity
  breaks). It cannot safely promote detector constants.
- Evidence: `evidence/post-cycle-release-20260713-044353`.

## Protected disconnect recovery Release — 2026-07-13 04:55 IST

- Protected HR+R10 mode no longer circularly rejects every history request.
  A verified WHOOP 4-class strap with a durable exact gap may make its next
  already-disconnected connection history-first. Automatic recovery cannot
  seize a healthy connected command pipe, cannot preempt an explicit workout,
  and cannot run for unknown/unverified hardware or overlap another generation.
- A deliberate user recovery action remains available while connected but
  retains the same workout, hardware, persistence, and generation safeguards.
  Historical frames must flush durably before ACK, and the exact gap remains
  pending until its existing 75% timestamp-bucket coverage gate is satisfied.
- Focused BLE recovery tests passed 78/78, static checks passed 176/176, and the
  full simulator build-for-testing succeeded. The signed Release installed and
  launched as `com.adidshaft.atria`.
- Physical post-install observation showed 21 additional accepted HR samples
  and 21 additional CRC-valid R10 frames with zero disconnect delta. The
  dormant recovery request stayed pending; no healthy live connection was
  disturbed merely because backlog exists.
- This mechanism transports and durably archives candidate historical rows.
  Metric repair remains evidence-gated: no historical layout version is yet
  whitelisted for HR/RR interpretation, so current production rows cannot
  repair strain, recovery, or workout HR until one exact layout is synchronized
  against live reference data. Stored historical 100 Hz R10 motion is also
  unproven, so Atria does not claim it can reconstruct exact missed steps after
  a disconnect.

## Coverage-gated guided step calibration Release — 2026-07-13 05:07 IST

- The existing six-stage in-app sequence now validates each stage from unique
  embedded R10 device seconds before it may advance. Raw rows are flushed and
  synchronized first; readiness requires at least 95% payload coverage, no
  device-time discontinuity, and no uncovered boundary longer than two seconds.
- Accepted fitter windows use the first and last validated device timestamps
  with an end-exclusive boundary rather than UI tap receipt time. A failed
  stage is discarded and repeated without deleting earlier validated stages;
  incomplete evidence can no longer produce a “Sequence complete” manifest.
- The fitter JSON contract and exact rest/100 slow/100 normal/100 brisk/200
  normal/rest order remain unchanged. Arming stays archive-only and cannot
  reconnect, read battery, mutate subscriptions, start history, or interrupt a
  workout.
- Focused plan/archive tests passed 16/16, static checks passed 176/176, and the
  full simulator build-for-testing succeeded. The signed Release installed and
  launched as `com.adidshaft.atria`.
- Physical post-install counters advanced by 42 accepted HR samples and 42
  CRC-valid R10 frames with zero disconnect delta. Calibration archival remains
  armed through its existing bounded retention window.

## Unified calibration-toolchain Release — 2026-07-13 05:17 IST

- The app validator, Swift fitter, Swift replay tool, and Python coverage
  summarizer now share nonzero embedded device timestamps, end-exclusive
  windows, duplicate removal, chronological ordering, and recursive CSV input.
- The fitter requires the exact six guided stages and counts, aligned rests of
  at least 60 seconds, at least 95% evidence coverage, zero device-time breaks,
  zero uncovered aligned boundary time, zero rest steps, at most 3% mean walk
  error, and at most 5% error for every walk. An overlapping, inverted, partial,
  duplicate-inflated, or receive-time-only capture fails closed.
- The in-app raw boundary accepts only unavoidable sub-second timestamp
  alignment (`<1,000 ms`); one missing full device second now rejects the stage.
  Rest windows are represented explicitly as zero expected steps in the Python
  audit rather than being mistaken for a missing manual count.
- Cross-tool tests passed 9/9, focused iOS calibration tests passed 17/17,
  static checks passed 176/176, both standalone Swift tools compiled, and the
  signed Release installed and launched successfully.
- Physical post-install counters advanced by 33 accepted HR samples and 31
  CRC-valid R10 frames with zero disconnect delta.

## Workout foreground/end responsiveness Release — 2026-07-13

- Active workouts now patch only live HR, steps, strain, and battery into the
  existing widget snapshot. They no longer recompute recovery, sleep cycles,
  daily rollups, and TRIMP on the main actor for every live invalidation.
- Route checkpointing and the final route-store write no longer synchronously
  block the main actor. The durable pending-workout intent remains in place
  until session and route persistence finish, and a failed route write schedules
  automatic completion rather than losing the saved workout.
- Focused route, widget invalidation, and foreground policy tests passed 32/32;
  static checks passed 176/176; the full simulator build-for-testing and signed
  device Release build succeeded.
- The Release installed and launched as `com.adidshaft.atria`. Over a physical
  15-second post-install check, accepted HR advanced 30 samples and CRC-valid
  R10 advanced 31 frames while disconnects remained unchanged at 3,652.

## Design-archive motion parity — 2026-07-13

- The supplied `Atria website design.zip` was inventoried as 52 app mockups in
  16 sections. It contains CSS-defined motion rather than Lottie/video assets;
  those motion signatures are being implemented as native SwiftUI rather than
  shipping the generated HTML runtime.
- Healthspan already uses the archive's slow cyan orb float, breathing glow,
  and independently drifting particles while keeping the weekly body-age value
  immutable during presentation. Reduce Motion freezes translation and scale.
- Recovery detail now reveals its score ring with the archive's 2.6-second
  `(0.22, 1, 0.36, 1)` ease-out curve, adds a restrained compositor-friendly
  halo pulse, animates numeric changes, and presents the final state immediately
  under Reduce Motion.
- Breathwork retains Atria's deliberate 5.5-breath/min physiological cadence
  but now follows the archive's 45/10/45 expand/settle/contract curve, including
  a brief Hold instruction and synchronized ring opacity. The countdown remains
  derived from elapsed session time rather than a second stateful timer.
- The archive's broader hierarchy is now the visual reference: honesty-first
  Live/Learning/Disconnected states, one metric hue, chart-first details, no
  more than two elevation levels, shared sleep/activity editors, and a full 9:16
  share canvas with controls outside the exported artwork.
- Static checks passed 176/176, simulator and signed device Release builds
  succeeded, and the Release installed/launched as `com.adidshaft.atria`.
  Post-install accepted HR and CRC-valid R10 totals advanced by 420 and 422
  respectively from the prior checkpoint while disconnects remained at 3,652.

## False-sleep evidence and activity deletion consistency — 2026-07-13

- Bounded recent strap-gravity evidence can no longer validate a multi-hour
  sleep window from 30 quiet rows. Promotion now requires at least 300 rows,
  at least 95% decoder-validated evidence, 30 minutes of actual timestamp span,
  no internal gap over five minutes, and the existing stillness/intensity gates.
  Diagnostics report observed timestamp coverage rather than the requested
  sleep-window duration.
- The exact 10:18 PM–2:05 AM quiet-awake regression remains rejected, the
  45-minute daytime nap remains reviewable but never auto-confirms, a stable
  five-hour HR-only main sleep remains reviewable, and a densely motion-validated
  fragmented night continues through the motion-preferred path.
- Deleting a workout now writes a bounded durable time-window tombstone. A
  rebuilt sensor candidate with at least five minutes or 70% overlap is
  suppressed even if its generated ID changes. An explicit user re-add clears
  the overlapping tombstone only after the new workout persists successfully.
- Eight focused detector/tombstone tests passed, including sparse/dense/invalid
  motion gates, exact quiet-awake rejection, nap/main-sleep preservation,
  regenerated workout suppression, and durable 64-window retention. Static
  checks passed 176/176 and the full simulator build-for-testing succeeded.
- The signed Release installed/launched as `com.adidshaft.atria`. Accepted HR
  advanced by 861 and CRC-valid R10 by 863 from the prior physical checkpoint,
  while disconnects remained unchanged at 3,652.

## Strain surface consistency Release — 2026-07-13

- Live Home, widget, notification, saved-session, and final workout TRIMP now
  share the same 15-second maximum telemetry-evidence gap. A 16–90 second strap
  dropout no longer invents cardiovascular load during the live view and then
  disappears after saving or relaunching.
- Live Activity workout strain no longer subtracts two nonlinear day-strain
  scores. A dedicated incremental accumulator integrates only samples after the
  explicit workout start, honors the captured biological sex/rest/max-HR, drops
  unknown gaps, and recomputes safely when pause intervals change. Its result
  matches the final pause-aware workout TRIMP for identical evidence.
- Trend `perDayStrains` now slices cross-midnight sessions through event-local
  civil-day intervals rather than assigning the full session to its start day.
- Workout share snapshots on both completion and Activity detail use the same
  completeness gate as Activity. Under 25% HR coverage, precise strain, average
  HR, peak HR, and zone minutes are withheld instead of publishing misleading
  numbers in the 9:16 card.
- Four targeted consistency tests passed; static checks passed 176/176; the
  signed Release built, installed, and launched as `com.adidshaft.atria`.
  Post-install accepted HR and CRC-valid R10 each advanced by 1,318 while the
  disconnect counter remained unchanged at 3,652.

## Recovered-HR strain projection (decoder gate pending) — 2026-07-13

- If a future historical layout becomes reference-validated, metric-usable
  archive HR will contribute through the same coverage-deduplicated TRIMP
  projection in Home, Activity/history daily rollups, and trend strain.
  `validatedMetricLayoutVersions` is currently empty, so this is a tested
  projection path rather than a production fallback claim. Archive-only days
  cannot yet contribute HR load.
- History trends consume the canonical rollup strain rather than recomputing a
  session-only parallel value. Archive-backed load therefore cannot appear on
  Home while vanishing from the trend average.
- The archive cache now covers the active physiological wake cycle instead of
  starting at civil midnight. A shift worker awake across midnight retains the
  post-wake recovered load from the prior civil date, and cache identity includes
  the wake boundary even when two projections are both empty.
- User-facing session-history TRIMP now uses the personal resting-HR baseline
  and profile max HR, matching Home, workout, widget, and rollup calculations;
  it no longer substitutes the session's own minimum HR as the load anchor.
- Four focused regressions passed; static checks passed 176/176; the signed
  Release built, installed, and launched as `com.adidshaft.atria`. Post-install
  accepted HR advanced 696 and CRC-valid R10 advanced 699 while disconnects
  remained unchanged at 3,652.

## Battery truth projection Release — 2026-07-13

- Every user-facing battery consumer now requires the same accepted reading to
  be no more than ten minutes old. Home, widgets, Live Activity, notifications,
  and strap-stream state show `Pending` after that boundary instead of reviving
  an old 0%, 100%, low-battery, or charging value.
- Motion and step capture fail open when battery evidence is stale or absent.
  A cached stale low reading can no longer disable R10 motion collection while
  the strap is otherwise delivering valid frames.
- Proprietary status packets cannot originate a charging claim. Charging/full
  is promoted only when a plausible one-to-five-point battery rise corroborates
  it; otherwise the reading remains level-only.
- Protected production mode intentionally continues to exclude Battery Service
  discovery because physical trials showed that discovery destabilized the
  sensor link. Its honest contract is a credible fresh value for ten minutes,
  followed by `Pending`, until a stable strap-native battery transport is
  validated.
- Four focused regressions passed and static checks passed 176/176. The signed
  Release built, installed, and launched as `com.adidshaft.atria`. Post-install
  accepted HR advanced 1,012 and CRC-valid R10 advanced 1,015 while disconnects
  remained unchanged at 3,652; the four-hour-old 65% cache correctly projected
  to strap-stream battery `-1` (`Pending`) rather than being shown as current.

## Not yet proven complete

- **Historical metric decoding:** protected recovery can archive backlog, but
  no historical layout version has a synchronized live HR/RR reference pair.
  The evidence gate therefore rejects all historical rows for metric repair;
  Atria must not claim offline HR/strain/workout reconstruction yet.
- **Exact strap steps:** the only replayable counted reference is the earlier
  charger-on 132-step control. The stated July 11 walk windows contain no R10
  motion frames in the retained archive. Production therefore keeps the fitted
  detector provisional and presents its count with `~`; it must not claim exact
  validation from missing evidence.
- **SpO2 and skin temperature:** no validated decoder/reference pair exists for
  this strap firmware. Atria correctly withholds percentages and absolute
  temperature instead of inventing health data.
- **Public workout URLs:** current sharing includes a portable image, a
  self-contained HTML recap, and explicit GPX. A recipient-accessible,
  revocable web URL still needs authenticated object storage, access control,
  deletion/revocation, and a web renderer; a local deep link would not work for
  ordinary recipients.
- **Activity-type inference breadth:** native phone motion can now veto driving
  and suggest Walk, Run, or Cycle conservatively. Strength, Dance, and other
  ambiguous contexts still require user confirmation; HR alone never assigns
  a type. Real driving/walk/run/cycle prompt trials remain necessary before
  claiming field-level classification accuracy.

## Completion gates still required

1. Replay multiple charger-free, manually counted walks with matching R10 data,
   including adjacent rest/driving-like negative windows, and validate error and
   false-positive bounds before removing `~`.
2. Validate SpO2 and temperature candidates against synchronized external
   references across multiple levels and users before promotion.
