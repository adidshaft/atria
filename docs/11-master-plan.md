# Master Plan — Maximize the WHOOP strap, with extreme accuracy

This is the single source of truth for what to build, what to fix, and how to make
the data as accurate as physically possible from this strap. It ends with a strict
`/goal` that executes the whole thing.

---

## 0. Where we are (baseline, all working)

- **Protocol fully reverse-engineered & validated:** `0xAA | len | CRC8(len) | payload | CRC32(payload)`. Realtime/HRV command (`[0x23,seq,0x03,0x01]` → CMD_RESP → `0x28` REALTIME_DATA on `61080005`) proven on macOS (`whoop_codec.py`, `probe.py`).
- **iOS app (standalone, no subscription):** live HR, 5 zones, smoothed display, contact detection, artifact rejection, resting baseline (learned), trend chart, sessions + history, capture/export, auto-save, background BLE, Recovery ring, Strain (0–21), Strain-Coach guidance.
- **Gate A unblocked on iOS:** realtime/HRV now streams on adidshaft's iPhone when
  the app uses a fresh scan-and-connect path, waits for `61080005` notify, settles
  3 seconds, then sends `TOGGLE_REALTIME_HR` using write-without-response. See §2.

---

## 1. Feature set — everything worth building

### Tier 1 — Core daily loop (have, polish)
- [x] Live heart rate, zones, smoothed + artifact-rejected
- [x] Recovery (HRV-driven when available, HR-proxy fallback)
- [x] Strain (0–21, TRIMP) + day accumulation
- [x] Strain Coach (push/rest guidance)
- [x] Resting-HR baseline that learns; resting trend
- [x] Sessions, history, per-session charts, time-in-zone

### Tier 2 — Unlock the proprietary channel (the prize)
- [ ] **HRV (RMSSD + SDNN + lnRMSSD)** from realtime RR — §2 fix required
- [ ] **Live RR tachogram** (beat-to-beat) view
- [ ] **Respiratory rate** (derived from RR via RSA / FFT of the tachogram)
- [ ] **SpO2 / blood oxygen** if exposed by a command opcode (probe for it)
- [ ] **Skin temperature** if exposed (probe device-info/opcodes)
- [ ] **Raw PPG + accelerometer** stream decode (events on `0004`/IMU `0x33`)
- [x] **Historical data download** (`0x16`/`0x17` path) — protocol-clean local archive from the strap; metric use remains fail-closed until current-session overlap + external validation

### Tier 3 — WHOOP-grade intelligence
- [ ] **Sleep detection** from overnight HR/HRV/motion (low-HR + low-motion windows → sleep stages estimate)
- [ ] **Daily HRV-at-wake** (the gold-standard recovery input): auto-capture the first stable window after wake
- [ ] **Strain target & "optimal day"** coaching with weekly periodization
- [ ] **Trends & insights:** 7/30/90-day Recovery, HRV, RHR, Strain with anomaly flags
- [ ] **Workout auto-detection** (sustained elevated HR → auto session + sport label)

Checkpoint: with only the strap and cabled iPhone, Atria now treats
strength-like/near-threshold HR evidence as a separate local
`activityCandidates` rollup instead of dropping it on the floor or falsely
counting it as a workout. The strict Gate E workout detector, HealthKit workout
export, and workout gate status still require sustained HRR50 evidence. Physical
device evidence:
`docs/evidence/app-usability/20260615T-activity-rollups-device-verify/`
(`activity_candidates=1`, `workouts=0`, `workout_gate_strict=1` for the saved
gym day).

Checkpoint: Gate F trend anomaly flags now use daily rollups instead of raw
session fragments, so reconnect chunks cannot inflate the anomaly sample count.
Physical iPhone evidence in
`docs/evidence/gate-f/20260615T-daily-rollup-anomaly-source-device-verify-3/`
logged 7/30/90-day trend rows with `anomaly_source=daily_rollups` and
`anomaly_days=3`; companion Gate Status evidence in
`docs/evidence/gate-f/20260615T-daily-rollup-anomaly-source-gate-status-device-verify/`
kept Gate F `partial` with `trend90_coverage_days=3` of `63` required days and
HRV/Recovery still reference-gated.

### Tier 4 — Product polish
- [ ] Onboarding (age → HRmax, profile)
- [ ] Notifications (recovery ready in the morning, strain target hit, low battery)
- [ ] HealthKit write (HR, HRV, workouts) so it feeds Apple Health/Fitness
- [ ] Apple Watch complication / widget (today's recovery + strain)
- [ ] iCloud/file backup of sessions

---

## 2. The HRV-on-iOS blocker — fix paths (priority order)

**Symptom:** command ACK'd (`w:ok`) but `0003`/`0005` never notify on iPhone; identical command works on macOS/bleak. Survives reboot (not GATT cache). MTU 247 (fine).

Fix paths, cheapest → deepest:
1. **Write-mode** — send command as write-WITHOUT-response (NUS-style). **Landed.**
2. **Connection recipe** — fresh scan-and-connect, never `retrieveConnectedPeripherals`; send START only after `0005` notify confirmed; settle ≥3s. **Landed.**
3. **On-device log diagnosis** — stream `WHOOPDBG` from the strap-connected iPhone to see exactly what the strap returns to the command. **Landed.**
4. **Pairing/encryption** — not needed for realtime after the write-mode/fresh-connect fix.
5. **Gate B RR continuity** — not needed for Gate A realtime unlock, but
   required before any HRV accuracy claim. Cross-checking `NoopApp/noop` showed
   the missing primary channel: standard BLE Heart Rate Measurement `2A37`
   carries HR plus R-R intervals, while WHOOP custom realtime `0x28` often
   reports `rr_count=0`. The app now parses `2A37` R-R as the primary live HRV
   source and treats `0x28` R-R as supplemental diagnostics unless it is the
   only real interval source available. Latest cabled-iPhone evidence in
   `docs/evidence/gate-b/20260613T132138Z-gate-b-2a37-reset-keep-recording/`
   produced a strict 300-second live `2A37` window (`raw=348`, `kept=318`,
   `conf=91.4`, `max_gap_s=2.845`). Clinical Gate B remains reference-pending
   until simultaneous external RR/IBI RMSSD agrees within `+/-5 ms`.
   Historical download remains a fallback/protocol-expansion track, not the
   primary live HRV path while `2A37` is working. Earlier `0x28` work: full
   payload logging proved zero-RR frames do not hide valid RR bytes, and START
   retry / STOP-START policy did not solve continuity. Current steering keeps
   work on the cabled iPhone channel and does not repair the Mac probe. EXP-4b
   found that `0x06` selectors `0605`, `0606`, and `0607`
   can raise live RR-bearing frame fractions above 90% in short segments, but a
   full isolated `0605` validation later fell back to `29.8%` RR-bearing frames
   with a `73.0s` RR gap, isolated `0606` improved to only `52.7%` with an
   `87.5s` gap, and isolated `0607` reached only `58.4%` with a `51.0s` gap.
   A delayed-capture ordered `0600`-through-`0605` run also failed (`24.1%` in
   the final `0605` state, `max_rr_log_gap_s=132.6`), but showed `0600` itself
   at `100.0%` for its 30-second segment before later selectors degraded
   continuity. Follow-up physical iPhone runs closed those narrowed leads:
   fit-controlled `0600,0601` reached only `33.4%` RR-bearing frames with
   `max_rr_gap_s=130.7`, and adaptive `0301` reached `59.6%` with
   `max_rr_gap_s=138.5`. Live START/selector iteration is paused. The next
   iPhone-only Gate B path is structured historical-transfer probing. Later
   cross-check of `madhursatija/whoof` corrected the historical command family:
   the old `0x06` selector path is retired; next test is abort `0x14 [00]`,
   high-frequency sync `0x60 [00]`, start historical `0x16 [00]`, metadata
   packet `0x31`, data packet `0x2f`, and `0x17` ACK with the trim index. Success
   requires `0x2f` frames on any WHOOP packet characteristic or live RR
   continuity that satisfies Gate B.

### Gate A device evidence

Verified on adidshaft's physical iPhone (`<DEVICE_ID>`) on
2026-06-12. Clean Debug build installed and launched with `devicectl`; simulator
was not used.

Key `WHOOPDBG` lines:

```text
notifyState ch=61080005-... notifying=1 err=nil
send mode=wwr cmd=03 seq=0 ... frame=aa0800a82300030199bce9cf
frame ch=61080003 len=16 hex=aa0c00fc24c603000200000051a34e9b
cmdResp ch=61080003-... payload=24c6030002000000
frame ch=61080005 len=28 hex=aa1800ff2802259d2b6a085c4c02190341030000
frame ch=61080005 len=28 hex=aa1800ff28022a9d2b6a40434c020a031f030000
```

Exit status: `rt:` frames are present on device (`0x28` on `61080005`) and RR
interval bytes are present in the realtime payload. Gate B can now replace the
temporary RMSSD-only path with clinical RR correction, confidence, tachogram, and
respiratory-rate derivation.

---

## 3. Extreme-accuracy program

Accuracy is a first-class feature. Every metric gets a defined method, a validation, and a confidence signal.

### 3.1 Heart rate
- Keep median smoothing for display; store **raw** for stats.
- Artifact rejection: reject |Δ| > 50 bpm vs recent median **and** require
  2 aligned samples before accepting a new level. If the last accepted HR sample
  is stale by more than 5s, treat the jump as a stale-median transition instead
  of permanently rejecting a real workout rise after a BLE/contact gap.
- **Contact/quality gate:** only feed resting/HRV when `hasContact` is stable for ≥10s.

### 3.2 HRV (once §2 unblocked) — do it the clinical way
- Compute **RMSSD, SDNN, pNN50, lnRMSSD** over a clean 5-min window.
- **RR artifact correction:** drop RR outside 300–2000 ms; drop beats where |RRn − RRn−1| > 20% (ectopic/motion); interpolate gaps.
- **Standardized capture:** "morning HRV" = first 3–5 min stable, still, after wake → this is the only number used for recovery baseline (matches WHOOP/Elite HRV methodology).
- Report a **confidence %** based on % of RR kept after correction.

### 3.3 Resting HR
- Define RHR as the **5th-percentile of HR during low-motion sleep windows**, not the session min (removes transient dips).

### 3.4 Strain
- Calibrate `HRmax` from onboarding (age or measured peak) and `HRrest` from learned baseline → personalized HR-reserve. This is the single biggest strain-accuracy lever.
- Use 1 Hz sampling; integrate TRIMP exactly over real dt.

### 3.5 Recovery
- When HRV present: **lnRMSSD vs personal rolling mean/SD (z-score)** → map to 0–100 (this is the scientifically grounded version of WHOOP recovery). Blend RHR z-score.
- Require ≥7 days of baseline before showing high-confidence recovery; show "learning" confidence before that.

### 3.6 Validation harness
- `docs/12-validation.md` + `validate_hrv.py`: replay captured CSVs through the
  HRV correction/metric functions and compare app HRV vs a reference (e.g., a
  Polar H10 session) once.

---

## 4. Implementation plan (phased, each phase = green build + on-device verify + commit)

**Phase A — Unblock HRV on iOS (§2).** Land write-mode + connection-recipe + log diagnosis. Verify `rt:`>0 and live RR on device. **Done 2026-06-12 on adidshaft's physical iPhone.**

**Phase B — HRV done right (§3.2).** RMSSD/SDNN/pNN50/lnRMSSD, RR artifact correction, confidence %, live tachogram view, respiratory rate. **Implementation landed and device-smoke-verified 2026-06-12; still needs a reproducible clean 5-minute WHOOP-side RR window and then a reference comparison for the ±5 ms exit.** Current physical-device evidence shows the app correctly stays `learning` when RR continuity is insufficient. Single START, STOP→START zero-RR restarts, and START-only zero-RR reasserts all received command responses but did not produce a clean 5-minute window. A debug iPhone probe that sent an extra `0x03 0x01` command 8 seconds after START produced one validation-ready 300-second window (`rmssd=44.2`, `conf=92`, `max_rr_gap_s=2.1`) in `docs/evidence/gate-b/20260612T140338Z-probe-command-ready-window.md`, but later full-wrapper attempts with the same probe command did not reproduce that continuity. EXP-4b then found a stronger iPhone-only live-continuity lead: `0605` yielded `100.0%` RR-bearing realtime frames for its 30-second segment, `0606` yielded `96.8%`, and `0607` yielded `92.4%`, with no historical `0x2f` download frames. Full isolated validations did not reproduce that result: `0605` produced `29.8%` RR-bearing frames with `max_rr_log_gap_s=73.0`, `0606` produced `52.7%` with `max_rr_log_gap_s=87.5`, and `0607` produced `58.4%` with `max_rr_log_gap_s=51.0`; all captures saved as `learning`. A delayed-capture ordered `0600`-through-`0605` run also failed (`realtime_rr_fraction=33.3%`, final `0605` segment `24.1%`, `max_rr_log_gap_s=132.6`), but showed `0600` at `100.0%` before later selectors degraded continuity. Follow-up physical iPhone runs closed the narrowed live-continuity leads: fit-controlled `0600,0601` produced only `33.4%` RR-bearing frames with `max_rr_gap_s=130.7`, and adaptive `0301` produced `59.6%` with `max_rr_gap_s=138.5`; both stayed `learning` and produced no `0x2f`. Historical batch 1 (`0600,0601,0602,0603,0601000000000100,0601000000001000`) produced no `0x2f` frames; replay now checks packet type across all WHOOP characteristics, not only `61080004`. The targeted delayed `0601000000001000` validation also failed (`realtime_rr_fraction=24.7%`, target segment `25.7%`, `max_rr_log_gap_s=105.7`, capture `ready=0`, `conf=35`) and produced no `0x2f`. Live START/selector iteration and the old `0x06` historical path are retired. The `whoof` historical smoke on the cabled iPhone (`1400,6000,1600`) proved `0x16` is real on this strap: command `0x16` ACKed, `0x31` metadata and `0x32` diagnostic frames arrived on `61080005`, and no `0x2f` appeared yet. Next Gate B implementation is `0x31` metadata decode plus the `0x17` ACK continuation loop. Success still requires `historical_2f_frames > 0` with a decoded clean 5-minute RR window, or live RR continuity of `>=90%` over 300 s with no `>3 s` gap. If that fails, keep that capture path in `learning` and proceed to non-HRV gates until sniffer/official-app evidence or a known transfer format is available. Displayed personal-baseline HRV still requires the current local data-sufficiency gates, and the `validated` tier still requires external RR/IBI agreement.

**Phase B update 2026-06-13:** the `0x31` metadata decode plus `0x17` ACK continuation loop is device-verified on adidshaft's physical iPhone in `docs/evidence/gate-b/20260613T-gate-b-history-ack-17/`. The run produced `historical_2f_frames=2764` on `61080005` and `0x17` ACK statuses `0001000000`. Live RR still failed Gate B (`realtime_rr_fraction=73.8%`, post-`0x16` segment `77.9%`, `max_rr_log_gap_s=45.8`), so HRV remains `learning`. Next Gate B work is no longer opcode churn; it is decoding the WHOOP 4.0 104-byte `0x2f` historical frame layout, reconstructing a clean 5-minute RR/IBI window, then checking RMSSD within ±5 ms of an external reference.

**Phase B update 2026-06-13 candidate-log run:** the app now logs `0x2f` history as raw candidates with `seq/cmd/unix7/subsec11` and was device-verified in `docs/evidence/gate-b/20260613T-gate-b-historical-candidate-log/`. The run captured `historical_2f_frames=3356` and kept HRV in `learning`. It also produced the strongest live RR continuity so far (`realtime_rr_fraction=99.4%`, `max_rr_log_gap_s=2.3`) but only for a 180-second run, not the required 300-second Gate B window. Next validation step: repeat this exact `1400,6000,1600` path with a full 300-second capture before claiming HRV readiness.

**Phase B update 2026-06-13 300-second attempt:** the full `1400,6000,1600` physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-1400-6000-1600-300s-validation/` did not pass Gate B. It collected real RR (`rr_values=318`, correction snapshot `raw=300 kept=287 conf=96`) but failed continuity (`realtime_rr_fraction=69.3%`, `max_rr_log_gap_s=35.5`, `hrv_ready=False`). The run simultaneously downloaded `historical_2f_frames=9082`, so the next improvisation is to rerun the same realtime trigger with historical ACK continuation disabled. HRV remains `learning`.

**Phase B update 2026-06-13 history-ACK disabled smoke:** the physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-disable-history-ack-smoke/` verified a debug `--disable-history-ack` path. The app logged `history_ack=disabled` and skipped `0x17` continuation ACKs for `0x31` metadata, reducing historical side traffic to `historical_2f_frames=50`. It still failed Gate B after `0x16` (`realtime_rr_fraction=53.7%`, `max_rr_log_gap_s=61.7`, `hrv_ready=False`). Segment evidence points away from parser failure and toward `0x16` coexistence: `0x03`, `0x14`, and `0x60` were each `100.0%` RR-bearing in their short windows, while `0x16` dropped to `48.5%` and emitted history frames. Next iPhone-only validation should omit `0x16` and test `0x14,0x60` only over a Gate-B-length window before returning to historical decode. HRV remains `learning`.

**Phase B update 2026-06-13 live/history isolation validation:** the physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-1400-6000-only-300s-validation/` omitted `0x16` and confirmed no historical interleaving (`historical_2f_frames=0`; all `61080005` packets were `0x28`). The strap did enter a long live RR window (`rr_values=360`; correction snapshots reached `raw=330 kept=319 conf=97`), but the strict Gate B continuity bar still failed (`realtime_rr_fraction=74.5%`, startup `max_rr_log_gap_s=66.3`, in-window `hrv_max_rr_gap_s=3.2`, `hrv_ready=False`). This confirms `0x14,0x60` isolates live from stored-session traffic but does not force immediate continuous RR. Next work should either start the 5-minute capture only after a sustained RR window or port the known `whoof` `0x2f` historical RR offsets. HRV remains `learning`.

**Phase B update 2026-06-13 gap-aware auto-capture smoke:** the app now supports `--auto-capture-max-rr-gap` and the physical iPhone smoke in `docs/evidence/gate-b/20260613T-gate-b-auto-capture-gap-gate-smoke/` verified the new decision variable on-device. The gate logged `max_rr_gap_s`, `max_gap_threshold_s`, and `gap_ok`, rejected broken RR windows, and started capture only after a later `rr_fraction_0.906` candidate. This is not a Gate B pass (`hrv_ready=False`, `capture_summary_ready=False`, `realtime_rr_fraction=51.7%`, `max_rr_log_gap_s=67.2`), but it gives the next live validation a stricter start condition. HRV remains `learning`.

**Phase B update 2026-06-13 historical offset smoke:** after 12+ hours of continuous wear, `docs/evidence/gate-b/20260613T-gate-b-historical-offset-log-smoke/` verified the historical candidate logger on adidshaft's physical iPhone. Live Gate B still failed (`hrv_ready=False`, `realtime_rr_fraction=72.5%`, `max_rr_log_gap_s=30.1`), but the strap produced `historical_2f_frames=3549`. The literal `whoof` RR offsets `19,21,23,25` do not fit this strap revision well (`kept=223`, `confidence_percent=2`), while the K-revision candidate offsets `64,66,68,70` are much stronger (`kept=11481`, `confidence_percent=81`, provisional `rmssd_ms=42.3`). This is progress toward a stored-session fallback, not a Gate B pass: the app logs `validated=0`, and historical HRV must stay out of the validated tier and HealthKit export until the historical layout is validated against timing and an external RR/IBI reference.

**Phase B update 2026-06-13 historical window validator:** the analyzer now reconstructs timestamped 300-second historical candidate windows and rejects layouts whose corrected RR duration does not match the window duration. This rejected the four-offset K-revision sequence (`duration_ratio=2.79`, `ready_windows=0`), so those fields cannot be treated as four sequential RR beats. Single-field offset `68` is the strongest remaining hypothesis (`ready_windows=1957`, `duration_ratio=0.92`, best-window `raw=313 kept=313 rmssd_ms=23.3`), but it remains unvalidated. Gate B still requires external RR/IBI reference agreement within ±5 ms before any historical HRV can leave `learning`.

**Phase B update 2026-06-13 historical HR agreement:** the analyzer now scores candidate RR offsets against the historical HR byte at payload offset `17`. Offset `68` has full coverage but only moderate HR agreement (`samples=3429`, `mean_hr=75.6`, `mean_implied_bpm=68.5`, `within_10_bpm_percent=52`). Literal `whoof` offset `19` agrees better with HR (`samples=1111`, `mean_hr=67.8`, `mean_implied_bpm=68.9`, `within_10_bpm_percent=79`) but is too sparse and gappy for Gate B. This keeps historical decode in hypothesis mode: no HRV from stored history may be surfaced until one layout is validated against external RR/IBI reference.

**Phase B update 2026-06-13 live/history overlap:** the analyzer now reports whether `0x2f` history and live `0x28` realtime frames overlap in strap time. The current physical-device evidence does not: downloaded history spans `1781170637.667` to `1781173932.969`, while live realtime spans `1781294771` to `1781294913`, separated by `120838.0s`. This means the current history block cannot validate offset `68` or offset `19` against live RR. Next iPhone-only protocol work should discover the `0x16`/`0x17` parameters that select recent/current stored history, or capture a history segment that overlaps a live RR window.

**Phase B update 2026-06-13 recent-history sweep:** the app now supports a physical-device `--history-recent-sweep` path that sends `0x16` variants from the first live realtime timestamp, with configurable offsets. The cabled iPhone smoke in `docs/evidence/gate-b/20260613T-gate-b-history-recent-sweep-smoke/` sent offsets `0,300` and captured `historical_2f_frames=3653`, but Gate B still failed (`hrv_ready=False`, `realtime_rr_fraction=11.5%`, `max_rr_log_gap_s=40.4`). The sweep moved `0x31` metadata into the current live range, but the actual `0x2f` payload `unix7` range remained old (`1781173925.279` to `1781177322.392`) with no live overlap (`separation_seconds=118234.6`). Do not surface historical HRV. Next iPhone-only work should decode/control the `0x31` metadata plus `0x17` trim/cursor semantics that appear to choose stored chunks.

**Phase B update 2026-06-13 ACK field logging:** the app now logs structured `0x31` metadata field candidates and supports debug `--history-ack-mode trim|index|unix|zero|none`. The physical iPhone control in `docs/evidence/gate-b/20260613T-gate-b-history-ack-field-log-smoke/` used the existing safe `trim` ACK mode, built/installed/launched on device, accepted `0x17` responses, and captured `historical_2f_frames=376`. End metadata exposed `trim=101191..101220`, `index=50/59`, and a stable u16 `15` field; start metadata exposed the packet family list `16,2,41,17,6`. History still did not overlap live time (`separation_seconds=118123.1`), so Gate B remains `learning`. Next experiment should compare ACK modes and measure whether the `0x17` cursor changes the selected `0x2f` payload range.

**Phase B update 2026-06-13 ACK-mode comparison:** `docs/evidence/gate-b/20260613T-gate-b-history-ack-mode-comparison/` compared `trim`, `index`, `unix`, and `none` on the physical iPhone. `none` stopped after `50` `0x2f` frames, proving `0x17` continuation is required. `trim` kept the expected transfer alive (`376` frames over a `360.5s` historical span). `index` and `unix` were accepted but redirected/mixed the payload stream into older ranges and diagnostic `0x32` traffic; no mode produced live/history overlap. Keep `0x17` in `trim` mode for the known path. The current-history selector is likely in the initial `0x16` request payload or a pre-transfer selector, not in the continuation ACK cursor. HRV remains `learning`.

**Phase B update 2026-06-13 GET_DATA_RANGE selector smoke:** the physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-history-get-range-selector-smoke/` tested the `whoof`/whoomp `0x22 [00]` `GET_DATA_RANGE` command before `0x16 [00]`, while keeping `0x17 trim`. `0x22` ACKed and returned a 69-byte status with both old-history-looking Unix candidates (`1774779641`, `1774779689`) and a current-ish Unix candidate (`1781296884`). The following `0x16` still downloaded old history (`historical_2f_frames=1885`, history `1774779641.103` to `1774781413.753`, live `1781296840` to `1781296983`, `overlap=0`, separation `6515426.2s`) and Gate B stayed `learning` (`realtime_rr_fraction=32.7%`, `max_rr_log_gap_s=30.6`, `hrv_ready=False`). Added `tools/analyze_data_range_response.py` to make future `0x22` evidence repeatable. Next selector work should derive a conservative `0x21 SET_READ_POINTER` experiment from `0x22`, then run `0x16 [00]` with `0x17 trim`; do not surface historical HRV from this block.

**Phase B update 2026-06-13 SET_READ_POINTER old-shape test:** the physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-history-set-read-pointer-old-shape/` tested `0x21 856d0000`, using the prior `0x22` old-range pointer-like value `28037`. The command produced no `61080003` response, its segment had `0.0%` RR-bearing realtime frames, and the following `0x16 [00]` still downloaded old history (`historical_2f_frames=878`, history `1774781409.907` to `1774782214.521`, live `1781297196` to `1781297318`, `overlap=0`, separation `6514981.5s`). This rejects the simple four-byte old-pointer shape. Short `0x14` and `0x60` windows again reached `94.7%` RR-bearing frames, but the run did not pass Gate B (`realtime_rr_fraction=71.1%`, `max_rr_log_gap_s=31.5`, `hrv_ready=False`). Stop blind `0x21` guessing; next work should either derive the real pointer layout from stronger evidence or run a live-only 300-second validation around `0x14,0x60`. HRV remains `learning`.

**Phase B update 2026-06-13 overnight live-RR continuity:** the unattended cabled-iPhone run in `docs/evidence/gate-e/20260613T-gate-e-overnight-autosave-run/` produced the first repeatable live WHOOP RR windows that satisfy the Gate B continuity decision variables without historical `0x2f` interleaving. The app summary reported `hrv_ready=True`, `rr_values=2083`, `last_hrv_max_rr_gap_s=2.0`, and `historical_2f_frames=0`. The repeatable analyzer `tools/analyze_live_rr_windows.py` found 9 real-RR-only 300-second ready windows; best window `2026-06-13 04:34:46.618` to `04:39:46.618` had `raw=294`, `kept=294`, `conf=100.0`, `max_gap_s=1.968`, `rmssd_ms=60.2`, `sdnn_ms=72.9`, `pnn50=38.6`, `lnrmssd=4.098`. This clears the live continuity acquisition blocker under tight-wear overnight/still conditions, but Gate B is still not fully passed until the same window or a repeat capture is compared against an external RR/IBI reference and RMSSD agrees within `±5 ms`. Until then, any user-facing HRV must remain confidence-gated and marked unvalidated/reference-pending.

**Phase B update 2026-06-13 live-only adaptive validation:** the physical iPhone run in `docs/evidence/gate-b/20260613T-gate-b-live-only-adaptive-300s-validation/` tested that live-only `0x14,0x60` path after 12+ hours of continuous strap wear. The app correctly waited for a short-window continuity candidate (`rr_fraction_0.906`) before starting the 300-second capture, with no historical interleaving (`historical_2f_frames=0`; `61080005` only `0x28`). The full Gate-B-length window still failed: `capture_summary ready=0`, `raw=173`, `kept=102`, `conf=59`, `realtime_rr_fraction=60.1%`, `hrv_max_rr_gap_s=54.3`, `max_rr_log_gap_s=54.7`, `hrv_ready=False`. This rejects the current live-only adaptive `0x14,0x60` variant as a Gate B solution under the available hardware conditions. HRV remains `learning`; next work should move to stronger historical-selector evidence or proceed with non-HRV gates while keeping HRV gated.

**Phase B update 2026-06-13 RR continuity retest:** after a short Gate E smoke produced `realtime_rr_fraction=0.950`, a full no-build 305-second physical-iPhone capture was run in `docs/evidence/gate-b/20260613T-gate-b-rr-continuity-300s-retest/`. The long window failed: RR started only after `rr_start_delay_s=124.1`, total `realtime_rr_fraction=0.288`, `max_rr_log_gap_s=30.8`, and `capture_summary ready=0 raw=127 kept=105 conf=83 window=132 reason=window`. This confirms the issue is intermittent continuity, not a parser failure; HRV remains `learning`.

**Phase B update 2026-06-13 history-only fallback isolation:** after the user pushed on local storage/chunking, `docs/evidence/gate-b/20260613T112657Z-history-only-selector-probe/` verified a new physical-iPhone `--history-only-probe` mode. The app skipped realtime START (`realtime_start=False`, `realtime_frames=0`) and sent `0x22 [00]` only after `61080005` notifications were active, then the selector sweep pulled `historical_2f_frames=3330` with `0x31` metadata and `0x32` diagnostics. This confirms the strap's stored-session path can be tested separately from live HRV capture, avoiding the live/history contention seen in the broad fallback sweep. The decoded block is not Gate-B-ready (`ready_windows=0`, `max_rr_gap_s=227.83`, `live_history_overlap=0`, no external RR/IBI reference), so historical RR remains provisional and HRV stays `learning`. Next iPhone-only work should refine the `0x22`/`0x16` selector or decode enough metadata to select current stored chunks; do not retry START policies as the main path.

**Phase B update 2026-06-13 data-range/history correlation:** `tools/analyze_data_range_response.py` now decodes `0x2f` frames through `whoop_codec.py` and reports which `0x22` u32 fields are nearest the actual downloaded historical range. Across the history-only selector probe and the earlier GET_DATA_RANGE / old-shape SET_READ_POINTER runs, body offset `40` exactly matched the first downloaded `0x2f` Unix timestamp, while body offset `48` was near the beginning of the same stored block. Body offset `56` was current-ish, but sending it as the current-Unix selector still pulled old March history. Next selector work should decode the record/cursor structure around offsets `40-60` instead of treating a single Unix-looking value as a complete pointer. HRV remains `learning`.

**Phase B update 2026-06-13 record-shaped selector sweep:** the app and launcher now support `current-record8`, `known-block-record8`, `range-window24`, and `record-shape-all` selector modes. Physical iPhone evidence in `docs/evidence/gate-b/20260613T114206Z-history-record-shape-selector/` ran history-only `record-shape-all` after `0x22 [00]`, sending `0x21` payloads copied from the `0x22` record body before `0x16 [00]` plus `0x17 trim`. The strap emitted `historical_2f_frames=3856`, so the record-shaped payloads did not kill the stored-transfer path, but the downloaded range still decoded to old March history (`2026-03-29T14:52:38Z` to `15:52:46Z`). Body offset `40` again matched the downloaded first history timestamp (`delta_s=18`), while the current-ish offset `56` still did not retarget current stored data in the combined sweep. This is not a Gate B pass (`ready_windows=0`, `live_history_overlap=0`, `gate_b_ready=0`, no external RR/IBI reference). Next work should isolate `current-record8` and `range-window24` in fresh history-only runs, and HRV remains `learning`/reference-pending.

**Phase B update 2026-06-13 isolated current-record8 selector:** `docs/evidence/gate-b/20260613T114825Z-history-current-record8-selector/` ran `current-record8` alone in history-only mode on the physical iPhone. The app sent `0x21 66432d6a28510000`, derived from the `0x22` current-ish offset `56` field (`1781351270`, `2026-06-13T11:47:50Z`), then `0x16 [00]` ACKed and streamed `historical_2f_frames=1901`. The actual `0x2f` range still decoded to old March history (`2026-03-29T15:52:08Z` to `16:21:18Z`), and the first downloaded timestamp exactly matched `0x22` body offset `40` (`delta_s=0`). This rejects `current-record8` as the current-history selector. Gate B remains `learning`/reference-pending (`ready_windows=0`, `live_history_overlap=0`, `gate_b_ready=0`).

**Phase B update 2026-06-13 isolated range-window24 selector:** `docs/evidence/gate-b/20260613T115126Z-history-range-window24-selector/` ran `range-window24` alone in history-only mode on the physical iPhone. The app sent `0x21 7451c969903600009951c969487500003b442d6aa00a0000`, copied from the `0x22` body offset `40...63` record window, then `0x16 [00]` ACKed and streamed `historical_2f_frames=2067`. The actual `0x2f` range still decoded to old March history (`2026-03-29T16:21:08Z` to `16:53:01Z`), and the first downloaded timestamp exactly matched `0x22` body offset `40` (`delta_s=0`). This rejects the current record-shaped selector family unless new evidence appears. Gate B remains `learning`/reference-pending (`ready_windows=0`, `live_history_overlap=0`, `gate_b_ready=0`), and the next productive work should pivot away from blind selector churn.

**Phase B update 2026-06-13 historical ranking cleanup:** `tools/analyze_historical_2f.py --rank-candidates` now gives a single conservative ranking across plausible single-offset historical RR hypotheses, combining 300-second window shape, duration consistency, HR-byte agreement, and live/history overlap while forcing `gate_b_ready=0` without external RR reference evidence. On the 12+ hour wear log `20260613T-gate-b-historical-offset-log-smoke`, offset `68` ranks first (`ready_windows=1957`, `kept=313`, `conf=100`, `max_gap_s=0.961`, `duration_ratio=0.92`, `rmssd_ms=23.3`) but still has only moderate HR agreement (`within_10_bpm=52%`) and no live/history overlap (`separation_seconds=120838.0`). This is the cleanest current historical hypothesis, not a Gate B pass. The next meaningful Gate B work is to obtain overlapping/current stored history or external RR reference evidence for offset `68`; otherwise continue non-HRV gates with HRV learning.

**Phase B update 2026-06-13 clean-RR follow-up:** after two short delayed-save smokes produced `realtime_rr_fraction=1.000`, a full physical-iPhone 300-second capture was run in `docs/evidence/gate-b/20260613T-gate-b-clean-rr-after-sleep-setup-300s/`. It failed the strict Gate B bar: adaptive capture could not start on continuity (`gap_ok=0`) and eventually timed out into an evidence capture; final summary was `capture_summary ready=0 raw=76 kept=76 conf=100 window=120 max_rr_gap_s=53.8 reason=window`, with overall `realtime_rr_fraction=0.222` and `max_rr_log_gap_s=232.7`. The CSV was pulled as `...learning.csv`. This confirms the short clean live bursts still do not satisfy continuous 5-minute RR; HRV remains `learning`.

**Phase B update 2026-06-13 current-store 300s RR recheck:** `docs/evidence/gate-b/20260613T-gate-b-current-store-300s-rr-recheck/` captured the first deliberate live-only Gate-B-ready 300-second window on the physical iPhone after the current-store platform run showed a stable short RR segment. Auto-capture waited for `rr_fraction_0.911` over the 60-second gate, then stopped on `capture_summary ready=1 elapsed=301 raw=299 kept=299 conf=100 window=300 max_rr_gap_s=2.0 reason=ready rmssd=60.8 sdnn=75.8 pnn50=46.0 lnrmssd=4.11 resp=10.0`. The full run had `realtime_rr_fraction=0.942`, `rr_values=383`, and `historical_2f_frames=0`; the ready CSV was pulled into the evidence directory. This clears the live continuity blocker under tight-wear/still conditions, but Gate B remains reference-pending until RMSSD is compared against an external RR/IBI recorder within `+/-5 ms`.

**Phase B update 2026-06-13 reference validator:** `tools/validate_hrv_reference.py`
now makes the final clinical reference check executable. It reads a WHOOP RR
capture CSV and an external RR/IBI CSV, applies the same Gate B artifact rules
to both streams (`300-2000 ms`, drop `|delta RR| > 20%`, confidence
`kept/raw`), requires both sides to satisfy the 5-minute readiness gate, and
passes only when RMSSD differs by `<= 5 ms`. Smoke evidence in
`docs/evidence/gate-b/20260613T101500Z-reference-validator-smoke/` verified a
same-file sanity pass (`rmssd_delta_ms=0.0`) and a fail-closed short-reference
case (`reason=reference_window`). This is not a Gate B pass because no external
RR/IBI reference file has been captured yet; it removes ambiguity from the final
comparison step.

**Phase B update 2026-06-13 HRV reference-pending guardrail:** `docs/evidence/gate-b/20260613T-gate-b-hrv-reference-pending-guardrail/` added an explicit `hrvReferenceValidated` bit to saved sessions and verified the final binary on the physical iPhone. Unreferenced saved HRV no longer feeds baseline learning, Recovery v2, daily/trend HRV, HealthKit HRV export, widget `validated` state, or recovery notifications. Device logs now show `daily_rollup ... hrv=learning`, `trend_window ... hrv=learning`, and `widget_snapshot ... hrv=reference_pending` while the external RMSSD comparison is absent.

**Phase B update 2026-06-13 overnight adaptive ready recheck:** with adidshaft asleep, strap tight on wrist, iPhone screen on and cabled, the app was built/installed/launched on the physical iPhone and run with a stricter adaptive live-RR gate in `docs/evidence/gate-b/20260613T-gate-b-overnight-adaptive-ready-recheck/`. The app waited for `rr_fraction=0.956`, `rr_frames=43/45`, and `max_rr_gap_s=1.8` before starting capture, then pulled a ready CSV: `capture_summary ready=1 elapsed=301 raw=308 kept=296 conf=96 window=300 max_rr_gap_s=2.0 rmssd=50.9 sdnn=69.7 pnn50=35.8 lnrmssd=3.93 resp=9.0`. Whole-run continuity was `realtime_rr_fraction=0.964` (`715/742` frames, `rr_values=740`, `max_rr_log_gap_s=2.0`), all `61080005` realtime packets were `0x28`, and `historical_2f_frames=0`. This makes the iPhone live-RR path reproducibly Gate-B-ready for continuity, but clinical Gate B is still not fully passed because there is no simultaneous external RR/IBI reference proving RMSSD within `+/-5 ms`. Keep HRV/Recovery reference-gated until that comparison exists.

**Phase B update 2026-06-13 sleep continuity result:** while adidshaft continued wearing the WHOOP tightly with the iPhone cabled, `docs/evidence/gate-b/20260613T-gate-b-sleep-continuity-result/` produced another real live-RR-only 300-second ready capture on the physical iPhone. The app waited for the adaptive gate (`rr_fraction_0.978`, `rr_frames=44/45`, `max_rr_gap_s=1.9`), then stopped on `capture_summary ready=1 elapsed=300 raw=299 kept=288 rejected_delta_over_20_percent=11 interpolated=11 conf=96 window=300 max_rr_gap_s=2.0 rmssd=49.0 sdnn=69.6 pnn50=32.6 lnrmssd=3.89 resp=learning`. Whole-run continuity was `realtime_rr_fraction=0.944`, `rr_values=344`, `max_rr_log_gap_s=2.0`, all realtime data was `0x28` on `61080005`, `historical_2f_frames=0`, and the ready CSV was pulled locally. This is the freshest result from the user's overnight setup: live HRV acquisition is working under still/tight-wear conditions, but clinical Gate B remains reference-pending until RMSSD is checked against an external RR/IBI reference within `+/-5 ms`.

**Phase B update 2026-06-13 2A37 primary RR path:** read-only `NoopApp/noop` inspection revealed that standard BLE Heart Rate Measurement `2A37` is the reliable HR/R-R source and custom `REALTIME_DATA` commonly carries `rr_count=0`. The app now parses full `2A37` payloads (`flags`, 8/16-bit HR, optional energy expended, little-endian R-R intervals in 1/1024s), logs `standardHR payload=... rrnum=... rr_ms=...`, feeds those real intervals into the existing HRV/RR ledger, and demotes `0x28` to supplemental diagnostics when `2A37` RR is fresh. The cabled physical iPhone run in `docs/evidence/gate-b/20260613T132138Z-gate-b-2a37-reset-keep-recording/` verified this path with `standard_2a37_rr_values=832`, `rr_source_0x28_used_values=0`, `capture_aborts=0`, and `capture_quality_resets=2`. The app no longer throws away the whole recording when a live RR gap appears; it checkpoints the real received RR chunk, resets the HRV window, and keeps recording until a clean 300-second window exists. The pulled CSV ended `capture_summary ready=1 elapsed=604 raw=345 kept=315 conf=91 window=300 max_rr_gap_s=2.8 quality_resets=2 rmssd=46.7 sdnn=58.6 pnn50=25.6 lnrmssd=3.84 resp=12.0`. Independent log replay on `2A37` found one strict 300-second window (`raw=348`, `kept=318`, `conf=91.4`, `max_gap_s=2.845`, `rmssd_ms=52.1`). This clears the iPhone live-continuity blocker through a standards-based channel. Gate B is still not clinically passed until simultaneous external RR/IBI reference comparison shows RMSSD within `+/-5 ms`; all downstream surfaces remain reference-gated.

**Phase B update 2026-06-13 RR-quality abort watchdog:** `WhoopBLEManager` now aborts an active HRV capture when rolling realtime RR evidence violates the Gate B continuity contract (`rr_fraction < 0.90` or `max_rr_gap_s > 3s` after the first 45 seconds), logs `capture_abort`, and writes a `ready=0 stop=rr_quality_abort` capture summary so bad windows cannot later surface as HRV. Physical iPhone evidence in `docs/evidence/gate-b/20260613T103515Z-still-5min-rr-abort-watchdog/` verified the behavior while adidshaft sat still: capture started at `rr_fraction_0.906`, then aborted at `fraction=0.500`, `max_rr_gap_s=30.8`; the pulled CSV stayed `learning`, and whole-run `realtime_rr_fraction=0.814`, `hrv_ready=False`. This is not a Gate B pass; it confirms that still posture alone does not guarantee live RR continuity and that phone-side buffering cannot recover RR intervals absent from `rrnum=0` live frames. Next work: retry from a fresh capture-local RR window after abort and keep pursuing validated historical/stored RR fallback plus external RR reference.

**Phase B update 2026-06-13 auto-retry fresh window:** the capture controller now separates display RR quality from capture-local RR quality and supports bounded auto-capture retries (`--whoop-auto-capture-max-attempts`, launcher `--auto-capture-max-attempts`). When a capture aborts for RR continuity, the app writes the failed window as `learning`, clears the capture-local quality window, and re-arms auto-capture so the next attempt starts only after fresh short-window RR evidence passes. Physical iPhone evidence in `docs/evidence/gate-b/20260613T104923Z-auto-retry-fresh-window/` verified the loop: attempt 1 started at `rr_fraction_0.906`, aborted at `fraction=0.889` with `ready=0 stop=rr_quality_abort`, then scheduled and started attempt 2 at a fresh `rr_fraction_0.906`. Attempt 2 reached `raw=255 kept=252 conf=99 window=221 max_rr_gap_s=2.0` before the harness ended, so it still remained `learning` (`reason=window`) and Gate B remains reference-pending. This implements honest local chunking/retry for live RR; it does not recover RR intervals absent from `rrnum=0` frames, so the stored-session/historical fallback is still required.

**Phase B update 2026-06-13 finalized auto-retry failure:** `docs/evidence/gate-b/20260613T105834Z-auto-retry-finalized-300s/` ran the bounded retry path to completion on adidshaft's physical iPhone while he sat still with the strap tight. The app built, installed, launched, started 5 auto-capture attempts, and exhausted all 5 without surfacing HRV (`hrv_ready=False`, `capture_summary_ready=False`, `auto_capture_starts=5`, `capture_aborts=5`, `auto_capture_exhausted=1`). The best partial attempts were real but too short: attempt 2 reached `raw=186 kept=181 conf=97 window=150` before `rr_gap_over_3s`, and attempt 4 reached `raw=109 kept=109 conf=100 window=99` before another gap. Whole-run live RR was only `realtime_rr_fraction=0.590` with `max_rr_log_gap_s=100.9`, and zero-RR frames had no hidden RR tail (`realtime_zero_rr_tail_nonzero_frames=0`). This answers the local-storage/chunking question: the app stores every RR interval iOS receives, but phone-side buffering cannot recover RR intervals absent from `rrnum=0` realtime frames. Keep the live watchdog/retry path, keep metrics in `learning` when continuity fails, and prioritize validated stored-session/historical decode for live dropout periods.

**Phase B/Gate H update 2026-06-13 current-Unix selector:** the app and launcher now support `--history-selector-sweep`, which derives a constrained `0x21` read-pointer candidate from the strap's own `0x22` data-range response and then requests `0x16` history. Physical iPhone evidence in `docs/evidence/gate-h/20260613T-gate-h-current-unix-selector/` verified the path: `0x22` returned a live-ish field at offset `56` (`value=1781335254`, `delta_s=-11` from live realtime), the app sent `0x21 d6042d6a`, then `0x16 [00]` ACKed and produced `historical_2f_frames=2399`. The transfer still decoded to the old March 29 stored range (`first_unix_offset_7=1774785649`, `last_unix_offset_7=1774787878`), so bare current-Unix does not retarget historical download. This is not a Gate B or Gate H pass; HRV remains reference-pending/learning, and the next selector shapes are `current-unix-prefix0` and `current-unix-prefix1`, one at a time.

**Phase B/Gate H update 2026-06-13 current-Unix prefix0 selector:** physical iPhone evidence in `docs/evidence/gate-h/20260613T-gate-h-current-unix-prefix0-selector/` tested `0x21 00<current_unix_le32>` derived from the `0x22` live-ish field (`value=1781335483`, `delta_s=-15`). This shape did ACK (`payload=248d210201000000`), so `0x21` appears to accept a prefixed current-Unix selector. The following `0x16 [00]` also ACKed, but the `0x2f` payload range remained old March history (`first_unix_offset_7=1774787872`, `last_unix_offset_7=1774790018`, `historical_2f_frames=2331`). Prefix0 is protocol evidence, not a retargeting win; do not feed historical HRV. Next remaining constrained shape is `current-unix-prefix1`.

**Phase B/Gate H update 2026-06-13 current-Unix prefix1 selector:** physical iPhone evidence in `docs/evidence/gate-h/20260613T-gate-h-current-unix-prefix1-selector/` tested `0x21 01<current_unix_le32>` from the `0x22` live-ish field (`value=1781335696`, `delta_s=-10`). Prefix1 also ACKed (`payload=2442210601000000`), followed by a `0x16 [00]` ACK (`payload=24451609020b0000`), but the returned `0x2f` range still stayed on old March history (`first_unix_offset_7=1774790035`, `last_unix_offset_7=1774790563`, `historical_2f_frames=590`). The run's live realtime RR fraction was `0.000`, so it cannot contribute to Gate B. Bare, prefix0, and prefix1 current-Unix selector shapes are now exhausted for this approach; historical RR remains provisional, and HRV stays reference-pending/learning.

**Phase B/Gate H update 2026-06-13 0x22 range mapping:** the app and launcher now support debug-only `--history-range-sweep`, `--history-range-payloads`, and `--history-selector-range-index`, and `WHOOPDBG data_range_response` logs include `request_index` plus `request_data` so each `0x22 GET_DATA_RANGE` response can be mapped to the exact request that produced it. Physical iPhone evidence in `docs/evidence/gate-b/20260613T123319Z-history-range22-sweep/` verified the initial `00..05` sweep, and `docs/evidence/gate-b/20260613T123710Z-history-range22-mapped-broad/` tested `00,06,07,08,09,0a,10,11,20,40,80,ff`. All responses kept the old-history fields at body offsets `40`/`48` (`1774803144`/`1774803189`) while offset `56` tracked current-ish time; no single-byte payload exposed a current stored-session range. A targeted selector run in `docs/evidence/gate-b/20260613T123915Z-history-selector-range-index/` proved response-index targeting works: range index `0` was skipped, range index `1` triggered `0x21 range_window24`, `0x16 [00]`, and `0x17 trim`, yielding `historical_2f_frames=1902`. The payload still decoded to the old March block (`2026-03-29T16:52:24Z` to `17:22:48Z`), with `ready_windows=0` under the literal `whoof` RR layout and `live_history_overlap=0`. This rules out more blind single-byte `0x22` sweeps as a useful near-term path; next historical fallback work should test a different init/selector family such as the `whoof` optional `0x14 [00]`/`0x60 [00]` sequence around `0x16`, or wait for official-app/sniffer evidence. HRV remains `learning`/reference-pending.

**Phase B/Gate H update 2026-06-13 whoof init-only transfer:** the app and launcher now support `--history-init-sweep` plus `--history-skip-range`, allowing a clean history-only command sequence without realtime START and without an automatic `0x22`. Physical iPhone evidence in `docs/evidence/gate-b/20260613T124517Z-history-whoof-init-only/` sent `0x14 [00]`, `0x60 [00]`, then `0x16 [00]` with `0x17 trim`. The strap accepted the path (`cmd_response_count=57`) and emitted `historical_2f_frames=2377`, `0x31` metadata, and `0x32` diagnostic packets. The download still advanced through the old March stored region (`2026-03-29T17:22:19Z` to `17:59:06Z`), not the current live session; the literal `whoof` layout had `ready_windows=0`, `live_history_overlap=0`, and `gate_b_ready=0`. This confirms the clean init sequence is a real transfer path but not a current-history selector. HRV/Recovery stay `learning`/reference-pending.

**Phase C — Recovery v2 (§3.5).** lnRMSSD z-score recovery + RHR blend; morning-HRV auto-capture; confidence gating.

**Phase C update 2026-06-13 Recovery v2 model slice:** Recovery now has a confidence-gated local model: high-confidence recovery requires validated HRV and at least 7 validated personal HRV baseline samples, then uses `50 + 16 * (0.75 * lnRMSSD_z - 0.25 * RHR_z)` clamped to `1...99`. When HRV is unavailable or the baseline is immature, the app labels Recovery as learning and does not show a resting-HR-only Recovery percent. The baseline persists rolling samples while keeping backward compatibility with the older EMA store. Device evidence in `docs/evidence/gate-c/20260613T-gate-c-recovery-v2-nslog-smoke/` built, installed, and launched on adidshaft's cabled iPhone and logged the earlier fallback diagnostic while HRV stayed `learning`; the stricter no-percent behavior is documented in the 2026-06-14 update below. Morning-HRV auto-capture is still pending, and Gate C is not done until the model is stable on real saved history with the required baseline.

**Phase C update 2026-06-13 morning-HRV auto-capture slice:** The app now has a guarded morning-HRV launch path (`--whoop-morning-hrv-check`, launcher `--morning-hrv-check`) that evaluates the local 04:00-11:59 morning window, configures strict adaptive RR capture, and logs the stillness evidence source. Because IMU is not decoded yet, stillness is explicitly labeled `still_source=rr_continuity motion_source=unavailable`; no motion-based sleep/still claim is made. Physical iPhone smoke evidence in `docs/evidence/gate-c/20260613T-gate-c-morning-hrv-smoke/` used `--morning-hrv-force` only to bypass the clock window and verified the path on device. The strap emitted `realtime_rr_fraction=0.000`, so the capture correctly saved as learning (`capture_summary ready=0 reason=no_realtime_rr`). Gate C remains incomplete until a real morning produces a validated 5-minute HRV sample and the personal baseline reaches the required 7-day maturity.

**Phase C update 2026-06-13 real morning-HRV ready check:** `docs/evidence/gate-c/20260613T-gate-c-real-morning-hrv-ready-check/` verified the guarded morning-HRV path on adidshaft's cabled physical iPhone during the actual morning window, not a forced clock bypass. The app logged `morning_hrv_check eligible=1 reason=morning_window local_time=08:56`, still labeled stillness honestly as `still_source=rr_continuity motion_source=unavailable`, waited for the adaptive RR gate (`fraction=1.000`, `rr_frames=20/20`, `max_rr_gap_s=1.2`), then pulled a ready CSV with `capture_summary ready=1 elapsed=301 raw=323 kept=323 conf=100 window=300 max_rr_gap_s=2.0 rmssd=49.4 sdnn=59.7 pnn50=35.1 lnrmssd=3.90 resp=11.0`. Whole-run realtime continuity was `realtime_rr_fraction=0.988`, `rr_values=770`, and `historical_2f_frames=0`. This proves the real morning auto-capture slice works when the strap supplies continuous RR, but it is not a full Gate C pass: launch diagnostics still showed `daily_rollup ... hrv=learning`, `trend_window ... hrv=learning`, `widget_snapshot ... hrv=reference_pending`, and `recovery_v2 ... uses_hrv=0` because there is no external RMSSD reference validation or 7-day validated HRV baseline yet.

**Phase C update 2026-06-13 latest validated HRV lookup:** Recovery, widget snapshots, and notification decisions now use the latest reference-validated saved HRV sample anywhere in local history instead of only checking the newest saved session. Physical iPhone evidence in `docs/evidence/gate-c/20260613T-gate-c-latest-validated-hrv-lookup/` verified the current store still has no validated HRV: `recovery_v2 ... confidence=fallback uses_hrv=0`, `widget_snapshot ... hrv=reference_pending`, and recovery/strain notifications skipped on fallback confidence. This is a correctness slice for future reference-approved HRV samples; Gate C still needs external HRV reference validation and a 7-day validated baseline.

**Phase C update 2026-06-13 baseline maturity diagnostic:** the app and launcher now support `--log-baseline` / `--whoop-log-baseline`, which logs the exact Recovery v2 maturity inputs. Physical iPhone evidence in `docs/evidence/gate-c/20260613T-gate-c-baseline-maturity-diagnostic/` built, installed, and launched against the real local store. The app logged `baseline_maturity sessions=11 resting_samples=8 resting_mean=66.6 resting_sd=4.2 hrv_validated_samples=0 hrv_required=7 hrv_ready=0 latest_validated_hrv=0 recovery_high_ready=0` and `baseline_hrv_stats count=0 ... state=learning`. In the same run, downstream surfaces stayed gated: `recovery_v2 ... confidence=fallback uses_hrv=0`, `widget_snapshot ... hrv=reference_pending`, and trend HRV remained `learning`. This improves Gate C auditability but does not complete Gate C; external HRV reference validation and at least 7 validated HRV baseline samples are still missing.

**Phase C update 2026-06-14 strict Recovery learning:** Recovery no longer returns a numeric resting-HR-only fallback percent. If HRV is unavailable, reference-pending, or the validated HRV baseline is immature, `recoveryV2` returns `percent=nil`, `confidence=learning`, and an explicit learning detail. Resting HR still contributes to the high-confidence model once HRV is reference-validated and the baseline has at least 7 validated HRV samples, but current dashboard/widget/notification surfaces must show learning instead of a pseudo Recovery number. Physical iPhone evidence in `docs/evidence/gate-c/20260614T134906Z-strict-recovery-learning-healthkit-device-verify/` built, installed, launched, and verified the guard: `recovery_v2 percent=-1 confidence=learning uses_hrv=0 detail=learning: need validated HRV` (`-1` is the diagnostic encoding for nil), `widget_snapshot ... recovery=learning confidence=learning hrv=learning`, `guidance_decision recovery=learning recovery_confidence=learning target=learning`, and notifications skipped Recovery/Strain with learning reasons. The same run used the newly granted Apple Health write permission: `healthkit_export status=authorization_cached ... hr_samples=267`, then `status=saved ... workouts=0 hrv_samples=0 ... incremental=1`, while `healthkit_reference_audit ... independent_hr_samples=0` kept Gate D reference validation honest.

**Phase G update 2026-06-14 current Health write permission reverify:** after the latest Apple Health write permission change, `docs/evidence/gate-g/20260614T141325Z-healthkit-write-permission-current-device-verify/` rebuilt, installed, and launched Atria on the cabled iPhone with HealthKit export enabled. The writer used cached authorization and saved a fresh incremental delta: `healthkit_export status=authorization_cached sessions=116 hr_samples=564 workouts=0 hrv_samples=0 read_hr=1`, followed by `healthkit_export status=saved sessions=116 hr_samples=564 workouts=0 hrv_samples=0 ledger_entries=115 idempotent=1 incremental=1`. Gate G stayed ready (`healthkit_entitlement=present`, `healthkit_available=1`, widget/app-group ready, backup current). HealthKit read access also worked, but `healthkit_reference_audit ... independent_hr_samples=0` means Gate D still lacks an independent non-Atria HR reference. The same standard-only capture logged `standard_2a37_frames=86` and `standard_2a37_rr_frames=0`, so this phase does not advance Gate B.

**Phase G update 2026-06-15 post-permission HealthKit live export:** after adidshaft granted Apple Health write access again, `docs/evidence/gate-g/20260615T-healthkit-permission-live-export-device-verify/` rebuilt, installed, and launched Atria on the cabled iPhone with `--healthkit-export` and gate-status logging. The export path used cached authorization, saved a fresh incremental HR delta (`healthkit_export status=saved sessions=197 hr_samples=63 workouts=0 hrv_samples=0 ledger_entries=196 idempotent=1 incremental=1`), and read Apple Health back successfully (`healthkit_export_verify status=ok reason=post_save expected_delta_hr_samples=63 expected_total_atria_hr_samples=48199 readback_atria_hr_samples=45550 total_hr_samples=45550 readback_covers_delta=1 data_appears=1`). Gate G logged `platform_ready=1`, `healthkit_entitlement=present`, `healthkit_available=1`, `healthkit_readback_status=ok`, and `healthkit_readback_data_appears=1`, so HR export/readback is verified on-device. Gate G remains `metric_gated`, not fully done, because HRV and workout writes are still blocked honestly by `healthkit_hrv_reference_pending+healthkit_workout_learning`; `healthkit_reference_audit ... independent_hr_samples=0` also confirms Atria-authored HealthKit rows are not being reused as an external HR reference.

**Phase G update 2026-06-14 HealthKit readback verification:** `docs/evidence/gate-g/20260614T145153Z-healthkit-readback-delta-device-verify/` rebuilt, installed, and launched Atria on the cabled physical iPhone after Apple Health write permission was available. The exporter saved an incremental HR delta (`healthkit_export status=saved sessions=122 hr_samples=118 workouts=0 hrv_samples=0 ledger_entries=121 idempotent=1 incremental=1`), then queried Apple Health back and logged `healthkit_export_verify status=ok reason=post_save expected_delta_hr_samples=118 expected_total_atria_hr_samples=45192 readback_atria_hr_samples=42618 total_hr_samples=42618 readback_covers_delta=1 legacy_reconciled=0 data_appears=1`. Gate G stayed ready with HealthKit entitlement, app-group/widget storage, backup, and notifications configured. The `legacy_reconciled=0` field is intentional honesty: this phase proves the new Atria-authored delta appears in Apple Health, not that every older local sample has been re-exported. `healthkit_reference_audit ... independent_hr_samples=0` still means Gate D has no independent Apple Health HR reference, and Gate B stayed reference-pending (`standard_2a37_frames=117`, `standard_2a37_rr_values=49`, `max_rr_log_gap_s=33.1`).

**Phase G update 2026-06-14 persisted HealthKit readback gate:** `docs/evidence/gate-g/20260614T181819Z-healthkit-readback-persist-device-verify/` made HealthKit readback a persisted platform-readiness criterion instead of an export-only log. The first physical-device pass saved a fresh delta (`healthkit_export status=saved sessions=159 hr_samples=772 workouts=0 hrv_samples=0 ledger_entries=158 idempotent=1 incremental=1`) and read Apple Health back successfully (`healthkit_export_verify status=ok reason=post_save expected_delta_hr_samples=772 expected_total_atria_hr_samples=47354 readback_atria_hr_samples=44743 total_hr_samples=44743 readback_covers_delta=1 legacy_reconciled=0 data_appears=1`). A second launch then logged Gate G with the persisted diagnostic: `healthkit_readback_status=ok`, `healthkit_readback_reason=post_save`, and `healthkit_readback_data_appears=1`, making `platform_ready=1`. Gate G remains `partial`, not ready, because HRV export and workout export are still blocked by the upstream truth gates: `metric_blockers=healthkit_hrv_reference_pending+healthkit_workout_learning`.

**Phase D/G update 2026-06-14 HealthKit independent reference check:** after
Apple Health permissions were available, a cabled iPhone run in
`docs/evidence/gate-d/20260614T151015Z-healthkit-independent-reference-current-device-verify/`
verified the current HealthKit state without changing code. HealthKit export
used cached read/write authorization and saved a fresh delta
(`healthkit_export status=saved sessions=127 hr_samples=321 workouts=0
hrv_samples=0 ledger_entries=126 idempotent=1 incremental=1`), and readback
confirmed Atria data appears in Apple Health (`healthkit_export_verify
status=ok ... readback_covers_delta=1 ... data_appears=1`). The independent
reference audit still found no non-Atria HR rows in the audited window:
`healthkit_reference_audit status=ok total_hr_samples=42939
atria_hr_samples=42939 independent_hr_samples=0 independent_sources=none
external_reference_ready=0`. Gate G remains ready, but Gate D remains partial
with `primary_blocker=independent_non_atria_hr_reference_missing`; Apple Health
cannot be used as the +/-2 bpm reference unless another source writes HR there.
The same bounded launch saw `2A37` RR in `44/44` frames with `52` RR values and
`max_rr_log_gap_s=3.5`, a useful Gate B clue but not a clinical pass because it
was only a 45-second run and exceeded the strict 3-second gap contract.

**Gate-status update 2026-06-15 fast deep audits:** current-state audits now log
gate status before slower backup/export launch tasks, and deep status emits an
explicit `WHOOPDBG gate_status_deep status=ready stage=e_deep_logged` marker as
soon as the `E.deep` row is available. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T190359Z-gate-status-deep-marker-device-verify/`
rebuilt, installed, launched, and verified `gate_status_complete=True` plus
`gate_status_deep_complete=True` without `HARNESS_ERROR`. The same run captured
the current truth: Gate B remains `reference_pending`; Gate C is `learning`
with `0/7` validated HRV baseline; Gate D is `partial` because HealthKit has
`0` independent non-Atria HR samples; Gate E is `partial` with the best stitched
workout candidate blocked by insufficient elevated HR (`p95=91`, `p99=106`,
`peak=122`, threshold `121`, elevated `3s`); Gate G has platform readiness but
is metric-blocked by HRV/workout truth gates; and Gate H protocol exit is
`ready` while historical metrics remain fail-closed/diagnostic-only.

**Reference-validation update 2026-06-15:** `reference_validate.sh` now runs a
Mac-side CSV preflight before launching the physical iPhone validation. The
preflight mirrors Atria's accepted RR/HR header shapes, reports parseable sample
counts and obvious blockers, and writes `rr-reference-preflight.txt` /
`hr-reference-preflight.txt` into the evidence directory. It is intentionally
not a gate validator: Atria on the iPhone remains the authority for Gate B/D
pass bits. Physical iPhone evidence in
`docs/evidence/reference-validate/20260615T-reference-preflight-device-verify/`
proved the preflight reports short-but-parseable references as not ready
(`RR reason=window`, `HR reason=pairs`) while the app still fails closed on
device (`gate_b_pass=0`, `gate_d_pass=0`). No metric gate was promoted.

**Reference-reducer update 2026-06-15:** `tools/analyze_gate_status.py` now
parses focused `WHOOPDBG hr_reference_package` and
`WHOOPDBG hr_reference_validation` rows into a real Gate D reducer row, matching
the Gate B RR reference reducer. The launcher now marks RR/HR reference
validation complete only after a terminal validator status, not `status=started`.
Physical iPhone evidence in
`docs/evidence/gate-d/20260615T-hr-reference-reducer-device-verify/` built,
installed, launched, connected to `ADIDSHAFT'S WHO`, exported a ready WHOOP-side
HR package (`samples=11236`, `duration_s=10801`, `coverage_percent=100`,
`avg_hr=58.1`, `peak_hr=85`), and failed closed against the current external CSV
with `reason=insufficient_pairs` (`reference_samples=5`, `pairs=10`,
`mean_delta_bpm=5.10`, `max_delta_bpm=6.00`, `gate_d_pass=0`). Gate D remains
partial; the next required proof is a real independent HR reference CSV with
enough paired samples inside the `+/-2 bpm` contract.

**Phase D — Strain accuracy (§3.4) + onboarding (HRmax/age, profile).**

**Phase D update 2026-06-13 profile/HRmax slice:** Strain now reads HRmax from a local athlete profile instead of an anonymous manual integer. The profile supports age-estimated HRmax (`208 - 0.7 * age`) or measured HRmax, migrates the previous `maxHR` value into the measured field, persists locally in `UserDefaults`, and logs `WHOOPDBG strain_profile ...` for device verification. Day strain, live zones, charts, and history details use the profile HRmax with learned RHR as before. This is a Gate D slice, not the full exit: onboarding still needs a polished first-run flow and the rest-to-max validation run.

**Phase D update 2026-06-13 onboarding slice:** First launch now presents a local profile onboarding sheet for age, HRmax source, and measured HRmax, with dismissal disabled until the profile is completed. The cabled-device debug launcher supports `--complete-onboarding` and logs `WHOOPDBG onboarding complete=1 ...` so this path can be verified without manual tapping during BLE runs. This remains a Gate D slice: Gate D is not complete until a physical-device rest-to-max validation shows personalized HR-reserve Strain reacting correctly across the effort range.

**Phase D update 2026-06-13 strain explainability slice:** The Strain gauge now explains day strain with a local confidence state and the exact personalized HR-reserve TRIMP inputs: saved TRIMP, live TRIMP, learned RHR, and profile HRmax. Physical iPhone evidence in `docs/evidence/gate-d/20260613T-gate-d-strain-explainability/` built, installed, launched, and logged `WHOOPDBG strain_explain strain=0.14 confidence=local trimp_total=0.27 trimp_saved=0.27 trimp_live=0.00 rest_hr=67 max_hr=191 saved_sessions_today=11`. The same run kept HRV honest in downstream surfaces (`widget_snapshot ... hrv=reference_pending`, `recovery_v2 ... uses_hrv=0`). This is an explainability/accuracy slice; Gate D still requires a physical rest-to-max validation run before it can pass.

**Phase D update 2026-06-13 guidance confidence guard:** Strain Coach now refuses to compute or display a daily strain target from `learning` or `fallback` Recovery. The dashboard passes Recovery into guidance only when Recovery v2 is `high`, and logs `WHOOPDBG guidance_decision ...` with the exact confidence reason. Physical iPhone evidence in `docs/evidence/gate-d/20260613T-gate-d-guidance-confidence-guard/` built, installed, launched, and logged `guidance_decision recovery=learning recovery_confidence=fallback target=learning strain=0.14 state=learning reason=recovery_confidence_fallback_not_high` while widget/Recovery stayed `hrv=reference_pending` and `uses_hrv=0`. The same short run confirmed the strap was streaming real RR (`realtime_rr_fraction=0.939`), but this was not a 300-second HRV capture and did not change Gate B/C reference status. Gate D still requires a physical rest-to-max validation run.

**Phase D update 2026-06-13 HR channel consistency diagnostic:** the app and launcher now support `--log-hr-consistency`, which compares standard BLE `2A37` HR against the proprietary realtime `0x28` HR byte when samples are within 5 seconds. The diagnostic logs all-run mean/max delta plus a rolling 20-pair readiness window so transient notification timing lag is visible without permanently failing the current channel state. Physical iPhone evidence in `docs/evidence/gate-d/20260613T-gate-d-hr-channel-consistency/` built, installed, launched, and reached `ready=1` by 10 pairs (`mean_delta=0.3`, `max_delta=1`); during a fast HR transition the all-run max reached `3 bpm`, then the rolling window recovered to `ready=1` at pair 100 (`recent_mean_delta=0.2`, `recent_max_delta=1`). This is an internal WHOOP channel/parser check, not the final chest-strap HR accuracy pass. Gate D still requires external HR validation and a real rest-to-max Strain run.

**Phase D update 2026-06-13 HR reference validator:** `tools/validate_hr_reference.py`
now makes the final `+/-2 bpm` HR reference check executable. It compares real
WHOOP HR samples against an external HR CSV, pairs samples within `5s`, requires
at least `30` pairs over `60s`, and passes only when both mean and max absolute
HR deltas are `<= 2 bpm`. Smoke evidence in
`docs/evidence/gate-d/20260613T102200Z-hr-reference-validator-smoke/` verified a
same-file sanity pass (`mean_delta_bpm=0.000`, `max_delta_bpm=0.000`) and a
fail-closed sparse-reference case (`reason=pairs`). This is not a Gate D pass
because no external chest-strap HR reference file has been captured yet.
The 2026-06-14 reference-validator honesty guard updated this tool too:
same-file comparison now fails by default as
`same_file_not_external_reference`; `--allow-self-compare` is parser-smoke only
and still prints `external_reference=0` plus `gate_d_pass=0`.

**Phase D update 2026-06-13 conservative RHR baseline repair:** short diagnostic
sessions no longer train resting baseline. Baseline learning now records
accepted/skipped evidence, accepts HR-only sleep candidates, future
reference-validated HRV windows, or long low-HR windows, and rebuilds the local
baseline from eligible saved sessions on app load and backup restore. Physical
iPhone evidence in
`docs/evidence/gate-d/20260613T134826Z-baseline-rebuild-device-verify/` repaired
a polluted baseline from `old_rest=79` to sleep-derived `new_rest=52`, with
`accepted=1 skipped=13`; daily rollups, workout preflight, strain explainability,
and backup verification all used the repaired RHR. Gate D still requires
external HR validation and a real rest-to-max Strain run.

**Phase D update 2026-06-13 strain HR-reserve zone summary:** Strain
explainability now includes saved+live HR-reserve zone seconds for the day:
`z0_lt30`, `z1_30_50`, `z2_50_70`, `z3_70_85`, and `z4_85_100`, plus dropped
gap seconds and min/max HR reserve. Physical iPhone evidence came from the
workout-background run in
`docs/evidence/gate-e/20260613T145402Z-workout-background-collection/`, which
logged `strain_zone_summary ... samples=15162 seconds_total=14581 z0_lt30=14446
z1_30_50=135 z2_50_70=0 z3_70_85=0 z4_85_100=0 dropped_gap_s=0 max_hrr=0.43`.
This makes the upcoming rest-to-max validation auditable by effort zone, but it
does not complete Gate D without external HR validation and a real range test.

**Phase D update 2026-06-14 rest-to-max validator:** the app and launcher now
support `--log-strain-validation` / `--whoop-log-strain-validation`. The
diagnostic groups saved local HR sessions by day, computes personalized
HR-reserve zone exposure, stream coverage, TRIMP, Strain, and combined blockers
against the Gate D rest-to-max criteria: `total>=600s`, `z0>=60s`,
`z3+z4>=60s`, `max_hrr>=0.85`, `stream_coverage>=75%`, plus an external HR
reference. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T-strain-validation-diagnostic-device-verify-2/`
built, installed, launched, pulled the current store, and logged
`strain_validation ready=0 rest_to_max_ready=0 ... stream_coverage_percent=64
... high_z3_z4_s=0 ... max_hrr_percent=49`. Gate D therefore remains partial
for concrete reasons:
`stream_coverage_below_75_percent+missing_high_zone_exposure+max_hrr_below_85_percent+external_hr_reference_missing`.
The same run had healthy live RR (`realtime_rr_fraction=0.973`,
`last_rr_quality_source=2a37`), so this is not a BLE/realtime-stream blocker.

**Phase D update 2026-06-14 dashboard validation surface:** the dashboard now
shows a Strain validation card using the same fail-closed rest-to-max summary as
`WHOOPDBG strain_validation`. It displays duration, stream coverage, low-zone
rest, high-zone exposure, max HR-reserve, and external HR reference status, and
logs `WHOOPDBG strain_validation_ui` whenever those blockers change. Physical
iPhone evidence in
`docs/evidence/gate-d/20260614T-strain-validation-dashboard-device-verify/`
built, installed, launched, confirmed the WHOOP link (`ble_link
status=connected`, `notifyState ch=61080005 notifying=1`), and logged
`strain_validation_ui ready=0 ... stream_coverage_percent=38 ... high_z3_z4_s=0
max_hrr_percent=51 external_hr_reference_validated=0`. This is faster
on-device diagnosis, not a Gate D pass: Gate D remains partial until an external
HR reference and real rest-to-max range test pass.

**Phase D update 2026-06-15 HR comparison capture preset:** the launcher now
supports `--gate-d-hr-comparison-capture` for the next real reference workout.
The preset uses standard BLE Heart Rate only, labels the run
`gate-d-hr-comparison`, defaults to a 20-minute capture, resets link/sample
diagnostics, logs workout preflight and live workout diagnostics, checkpoints
the local session, exports an HR reference package, writes and verifies a
session backup, and can pull both artifacts from the cabled iPhone. Physical
iPhone smoke evidence in
`docs/evidence/gate-d/20260614T185419Z-hr-comparison-preset-device-verify/`
verified `standard_hr_only enabled=1 realtime_start=skipped`, workout preflight
with `rest_hr=52 max_hr=189 threshold_hr=121`, backup verification
`digest_match=1`, and successful pull of the Atria HR CSV, manifest, and backup
JSON. This is capture tooling, not a Gate D pass: the short smoke correctly
logged `workout_validation status=learning reason=no_saved_session`, and the
gate still needs an independent HR reference plus a real rest-to-max/workout
comparison before Strain accuracy can be marked complete.

**Phase D update 2026-06-15 full blocker honesty:** Gate D status now reports
the full strain-validation blocker instead of collapsing the row to only
`independent_reference_missing`. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T190640Z-gate-d-full-blocker-device-verify/`
rebuilt, installed, launched, and verified the Gate D row now matches
`WHOOPDBG strain_validation`: `stream_coverage_below_75_percent`
`+missing_high_zone_exposure+max_hrr_below_85_percent`
`+external_hr_reference_missing`. The current store is therefore not a
rest-to-max proof for four concrete reasons: stream coverage is `39%`,
high-zone exposure is `0s`, max HR reserve is `51%`, and HealthKit still has
`0` independent non-Atria HR samples. This is diagnostic honesty only; Gate D
remains partial.

**Phase D tooling update 2026-06-15 strain verifier completion:** focused
`--log-strain-validation` runs are now first-class verifier runs. The launcher
tracks `strain_validation_complete` and fails with
`HARNESS_ERROR=strain_validation_incomplete` if the physical-device log does not
emit `WHOOPDBG strain_validation`. `tools/analyze_gate_status.py` also
synthesizes a Gate D row from a strain-only log. Physical iPhone evidence in
`docs/evidence/gate-d/20260615T-strain-harness-completion-device-verify/`
built cleanly, installed/launched Atria, and completed with
`strain_validation_complete=True`. Current Gate D truth remains partial:
`stream_coverage_percent=39`, `high_z3_z4_s=0`, `max_hrr_percent=51`, and
`external_hr_reference_validated=0`, yielding blocker
`stream_coverage_below_75_percent+missing_high_zone_exposure+max_hrr_below_85_percent+external_hr_reference_missing`.

**Phase D update 2026-06-14 HR reference package export:** the app and launcher
now support `--whoop-export-hr-reference-package` /
`--export-hr-reference-package`. A physical-device run exports the best saved
real `2A37` HR segment as a validator-ready CSV plus JSON manifest, logs
`WHOOPDBG hr_reference_package`, and can pull the files with
`--pull-reference-package`. The manifest is intentionally fail-closed:
`external_reference_required=1`, `reference_validated=0`, and `gate_d_pass=0`.
Physical iPhone evidence in
`docs/evidence/gate-d/20260614T-gate-d-hr-reference-package-device-verify/`
built, installed, launched, and pulled a 11,236-sample, 10,801-second
overnight HR package with `coverage_percent=100`, `avg_hr=58.1`, `peak_hr=85`,
and `resting_hr=47`. The validator parser smoke passed only with
`--allow-self-compare`, while the default same-file run failed with
`reason=same_file_not_external_reference`, proving the honesty guard still
holds. This removes a workflow bottleneck for Gate D, but it is not the exit;
the CSV must still be compared against an independent HR reference with
`tools/validate_hr_reference.py` and pass the `+/-2 bpm` contract.

**Phase D update 2026-06-14 CSV HR reference diagnostics:** `docs/evidence/gate-d/20260614T182642Z-csv-hr-reference-diagnostics-device-verify/` persists the last CSV HR-reference validation attempt whether it passes, fails, is missing, or is cleared. Clearing reference inputs now clears the persisted HR validation bit, while the validator records `csv_reference_status`, `csv_reference_reason`, pair counts, reference sample counts, deltas, and within-tolerance percent for Gate D/UI diagnostics. Physical iPhone evidence built the app, cleared missing inputs, and logged `hr_reference_validation_record status=missing reason=missing_external_reference_file ... reference_validated=0`; the dashboard emitted `hr_reference_ui ... csv_status=missing ... fail_closed=1`; and Gate D logged `csv_reference_status=missing`, `csv_reference_reason=missing_external_reference_file`, and `csv_external_hr_reference_ready=0`. Gate E still refused the best workout-like span honestly: `workout_next_action=validate_wrist_hr_underreporting_or_profile_before_more_workouts`, `workout_best_p95_hr=91`, `workout_best_p99_hr=106`, and `workout_threshold_hr=121`. This does not pass Gate D/E, but it removes ambiguity: the next real unlock is an independent HR reference or a future sustained-HR workout, not a looser detector.

**Phase E — Sleep & auto-detect.** Overnight sleep estimate; workout auto-detection; daily rollups.

**Phase E update 2026-06-13 HR-only detector slice:** Saved sessions now receive a local activity classification. Workout candidates use sustained elevated HR against learned RHR and profile HRmax, while overnight low-HR windows are labeled only as low-confidence sleep candidates because motion/IMU is not decoded yet. Detections render in History and log `WHOOPDBG activity_detect ...` when sessions are saved. This is useful daily signal, but not Gate E complete until a real night and workout are detected correctly on device, and sleep confidence includes low-motion evidence or a documented fallback.

**Phase E update 2026-06-13 unattended save slice:** The cabled-device launcher now supports `--auto-save-session-after N`, which forwards `--whoop-auto-save-session-after N` and makes the app finish/persist the current live HR session through the normal local `SessionStore` path without waiting for disconnect. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-delayed-session-save-label-smoke/` verified `session_auto_save status=saved samples=21 duration_s=19 avg_hr=65 peak_hr=69 resting_hr=62 hrv=learning label=gate-e-delayed-session-save-label-smoke`. This makes overnight evidence runs durable, but Gate E still requires a real overnight low-HR session and a correctly detected workout; sleep confidence remains low until motion/IMU is decoded or the HR-only fallback is explicitly accepted.

**Phase E update 2026-06-13 overnight run:** `docs/evidence/gate-e/20260613T-gate-e-overnight-autosave-run/` attempted a 4-hour cabled-device run with delayed save at `12600s`. The run streamed for about 51 minutes and captured strong Gate B RR continuity, but ended early with `com.apple.dt.CoreDeviceError error 3` / `com.apple.Mercury.error 1001` remote-process invalidation before the delayed save timer. No `session_auto_save status=saved` or `activity_detect` row was produced, so this is not a Gate E pass. Next Gate E run needs either a shorter periodic save cadence, a background-safe app-side checkpoint, or a reconnect/resume strategy so a Mac/CoreDevice debugging interruption does not lose the overnight session.

**Phase E update 2026-06-13 periodic save fallback:** the app and launcher now support `--auto-save-session-every N` / `--whoop-auto-save-session-every N`, which periodically finishes and persists real live-HR chunks through `SessionStore` with `mode=periodic`. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-periodic-autosave-label-smoke/` verified labeled periodic saves: chunk 1 saved `18` samples over `16s`, chunk 2 saved `21` samples over `19s`, both with the requested label and `hrv=learning`. This reduces data loss when CoreDevice drops during unattended runs, but it is not a sleep-detection pass because short chunks do not meet the 3-hour HR-only sleep-candidate threshold. Next overnight run should use periodic checkpoints plus a longer app-side/session-merge strategy if sleep detection must survive debug-console loss.

**Phase E update 2026-06-13 live-session checkpoint path:** periodic chunks were not enough for sleep detection because each save reset the live session. The app and launcher now support `--checkpoint-session-every N` / `--whoop-checkpoint-session-every N`, which snapshots the same live session ID and upserts it through `SessionStore` without clearing the in-memory samples. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-session-checkpoint-smoke/` verified growing checkpoints at `15s`, `36s`, and `56s` with `mode=upsert`, plus `realtime_rr_fraction=0.901`. Follow-up evidence in `docs/evidence/gate-e/20260613T-gate-e-checkpoint-backup-smoke/` verified local backup/verify of `12` persisted sessions. This is now the preferred unattended overnight fallback: the persisted session can grow past the 3-hour HR-only sleep-candidate threshold while still surviving a later Mac/CoreDevice console drop. Gate E still requires an actual overnight session and workout detection on device.

**Phase E update 2026-06-13 overnight sleep candidate verified:** `docs/evidence/gate-e/20260613T-gate-e-overnight-checkpoint-run/` ran on the cabled physical iPhone for just over 3 hours with `--checkpoint-session-every 300`. The app persisted `36` growing checkpoint upserts; checkpoint 36 saved `11239` samples over `10803s`, `avg_hr=58`, `peak_hr=85`, `resting_hr=53`, `hrv=73`, and emitted `WHOOPDBG activity_detect kind=Sleep candidate confidence=low ... reason=HR-only overnight low-HR window; motion not decoded source=checkpoint`. Follow-up verification in `docs/evidence/gate-e/20260613T-gate-e-overnight-checkpoint-verify/` logged `detections=1`, wrote a local backup with `13` sessions / `938780` bytes, and verified it with `session_backup_verify status=ok`. This closes the sleep-candidate half of Gate E using the documented low-confidence HR-only fallback; Gate E still needs workout auto-detect on device before the full gate is passed.

**Phase E update 2026-06-13 daily rollups + workout readiness:** the app and launcher now support `--log-daily-rollups` / `--whoop-log-daily-rollups`, which logs daily local rollups and per-session workout-readiness diagnostics: duration, avg/peak HR over resting baseline, elevated-zone seconds, elevated fraction, and required elevated seconds. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-daily-rollup-workout-readiness/` verified the real saved sleep day: `daily_rollup day=2026-06-13 sessions=10 workouts=0 sleep_candidates=1 duration_s=11016 strain=0.14 hrv=73 rhr=53`. The same evidence correctly refused to call the overnight session a workout: `ready=0`, `avg_over_rest=-9`, `peak_over_rest=18`, `elevated_s=0`, `required_elevated_s=1200`. This completes the daily-rollup diagnostic slice and makes the remaining workout verification explicit; Gate E still needs a real elevated-HR workout captured and detected on device.

**Phase E update 2026-06-13 sustained workout guardrail:** workout auto-detection now matches the Gate E wording more strictly: a session must last at least 10 minutes, accumulate enough elevated HR seconds above the personalized threshold, and include a continuous elevated bout; a single peak or average-HR bump can no longer classify a session as a workout. The app logs the new decision variable as `WHOOPDBG workout_sustained ... longest_bout_s=... required_bout_s=... decision=...`. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-sustained-workout-detector-guardrail/` built, installed, and launched on adidshaft's cabled iPhone, then verified the current store still has `workouts=0 sleep_candidates=1`. The overnight session stayed correctly non-workout: `workout_sustained label=gate-e-overnight-checkpoint-run longest_bout_s=0 required_bout_s=480 elevated_s=0 required_elevated_s=1200 decision=learning`. This is an accuracy guardrail, not a Gate E exit; Gate E still needs a real elevated-HR workout captured and detected on device.

**Phase E update 2026-06-13 sleep RHR source:** RHR for HR-only sleep candidates now uses the 5th percentile of the overnight low-HR window, while non-sleep sessions keep the prior 10th-percentile fallback. This moves the implementation closer to the plan's robust sleep-window RHR definition without pretending motion exists. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-sleep-rhr-source/` built, installed, launched, and logged `daily_rollup day=2026-06-13 sessions=11 workouts=0 sleep_candidates=1 duration_s=11613 strain=0.14 hrv=learning rhr=52` plus `resting_source label=gate-e-overnight-checkpoint-run value=52 source=hr_only_sleep_candidate_5th_percentile stable_10th=53 sleep_5th=52`. The same run kept sleep low-confidence/workout learning and HRV reference-pending. Gate E remains incomplete until a real workout is detected and sleep confidence includes motion/IMU evidence or an explicitly accepted HR-only fallback.

**Phase E update 2026-06-13 broken-sleep checkpoint run:** `docs/evidence/gate-e/20260613T-overnight-sleep-continuity-run-2/` ran on the cabled physical iPhone while adidshaft slept with interruptions. The checkpoint path persisted 17 growing upserts of the same local live session, ending at `samples=5303 duration_s=5099 avg_hr=61 peak_hr=101 resting_hr=54 hrv=learning`. The run was correctly not promoted to a sleep candidate because it was about 85 minutes, below the 3-hour HR-only threshold, and post-wake verification in `docs/evidence/gate-e/20260613T-overnight-sleep-continuity-run-2-postwake/` logged `daily_rollup day=2026-06-13 sessions=12 workouts=0 sleep_candidates=1 duration_s=16712 strain=0.62 hrv=learning rhr=52` plus `workout_sustained label=gate-e-overnight-sleep-continuity-run-2 ... decision=learning`. The same evidence found 9 clean 5-minute RR windows on iPhone (`rr_beats=4296`; best visible window `raw=294 kept=285 conf=96.9 max_gap_s=2.071 rmssd_ms=68.1`), while post-wake realtime RR dropped to `realtime_rr_fraction=0.338`. This strengthens the contact/physiology-state hypothesis for RR continuity and confirms downstream honesty (`widget_snapshot ... hrv=reference_pending`, `recovery_v2 ... uses_hrv=0`). Gate E remains incomplete until a >=3-hour sleep candidate or explicitly accepted shorter/broken-sleep fallback and a real workout are verified on device.

**Phase E update 2026-06-13 live workout diagnostic path:** the app and cabled-device launcher now support `--log-live-workout-every N` / `--whoop-log-live-workout-every N`, which logs the same sustained-workout readiness variables from the current live session without resetting it or changing classifier thresholds. Physical iPhone evidence in `docs/evidence/gate-e/20260613T062305Z-gate-e-live-workout-diagnostic-smoke/` built, installed, launched, and logged six live ticks with `threshold_hr=134`, `elevated_s=0`, `longest_bout_s=0`, and `ready=0`, plus checkpoint upserts at 30-second intervals. This validates the live workout evidence path and correctly avoids classifying a wake/rest run as a workout. Gate E still needs a real elevated-HR workout captured and detected correctly on the physical iPhone.

**Phase E update 2026-06-13 workout validation verifier:** the app and launcher now support `--verify-workout-label LABEL` plus `--verify-workout-after N`, which logs a delayed `WHOOPDBG workout_validation ...` verdict from the persisted local sessions. Physical iPhone evidence in `docs/evidence/gate-e/20260613T063203Z-gate-e-workout-validation-verifier/` built, installed, launched, and verified the prior wake/rest smoke label as `status=learning reason=duration_below_10m`, with `elevated_s=0`, `longest_bout_s=0`, and `workouts_matching=0`. This gives the next real workout attempt a single-run pass/fail line without loosening the detector. Gate E remains open until a real elevated-HR workout produces `workout_validation status=ready` on the physical iPhone.

**Phase E update 2026-06-14 workout near-miss diagnostics:** the workout
detector now exposes a diagnostic-only `near_miss` state in
`WHOOPDBG workout_replay_summary`, `gate_status gate=E`,
`workout_validation`, and `tools/analyze_workout_store.py`. Near miss requires
at least 10 minutes of observed saved HR, at least 20% sparse stream coverage,
and a peak within 5 bpm of the personalized HRR50 threshold or some true
elevated time. It never increments `workout_days`, writes workouts, or changes
the strict sustained-workout gate. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-workout-near-miss-device-verify/` built,
installed, launched, pulled the current store, and logged `workout_near_miss=1`
for the global best saved aggregate while keeping `workout_days=0` and
`workout_saved_ready=0`. The blocker is now concrete:
`stream_coverage_percent=23`, `peak_hr=120`, `threshold_hr=121`,
`elevated_s=0`, and `near_miss_reason=stream_coverage_low+peak_within_1_bpm_below_threshold+elevated_seconds_below_required+continuous_bout_below_required`.
The specific `Auto-saved` gym label was worse (`stream_coverage_percent=29`,
`peak_hr=114`, `threshold_gap_bpm=7`, `near_miss=0`), so the gym attempt is not
a missed pass; it lacked enough continuous captured elevated HR. Gate E remains
open until a real workout validates as `status=ready`.

**Phase E update 2026-06-14 activity-candidate fallback:** near-miss saved
sessions and aggregates now surface through `--log-activity-detections` as
low-confidence `Activity candidate` rows. This is deliberately not a workout
pass: it does not increment `workout_days`, does not write HealthKit workouts,
and does not satisfy Gate E. It exists so a strength-training or gappy-link
attempt produces an honest result instead of disappearing when sustained HR
criteria are not met.

**Phase E update 2026-06-13 workout preflight target:** the app and launcher now support `--log-workout-preflight` / `--whoop-log-workout-preflight`, which logs the personalized sustained-workout target before an attempt. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-workout-preflight/` built, installed, launched, and logged `workout_preflight rest_hr=67 max_hr=191 threshold_hr=134 zone70_hr=134 reserve_hr=97 min_duration_s=600 min_elevated_s=300 min_bout_s=180`. The smoke verifier correctly stayed learning with `workout_validation status=learning reason=no_saved_session`, and the short awake run had `realtime_rr_fraction=0.000`, reinforcing that HRV must remain tied to still/clean RR windows while workout/strain can proceed from HR. Gate E remains open until a real >=10-minute elevated-HR workout is checkpointed and validates as `status=ready` on the physical iPhone.

**Phase E update 2026-06-13 post-wake sleep validation:** the app and launcher now support `--verify-sleep`, `--verify-sleep-label`, and `--verify-sleep-after`, which log a single `WHOOPDBG sleep_validation ...` verdict from saved local sessions. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-postwake-sleep-validation/` built, installed, launched, and selected the real overnight checkpoint session: `sleep_validation status=ready reason=overnight_low_hr_window matched_label=gate-e-overnight-checkpoint-run duration_s=10803 samples=11239 avg_hr=58 peak_hr=85 rest_hr=67 sleep_rhr=52 overnight=1 low_hr=1 sleep_candidates_matching=1 confidence=low`. The same run logged `activity_detect_summary sessions=16 detections=1` and `daily_rollup day=2026-06-13 sessions=13 workouts=0 sleep_candidates=1 duration_s=16799 strain=0.73 hrv=learning rhr=52`. This strengthens the sleep half of Gate E, but sleep remains low-confidence because motion/IMU is unavailable, and Gate E remains open until a real elevated-HR workout is captured and detected correctly on the physical iPhone.

**Phase E update 2026-06-13 broken-sleep aggregate detector:** sleep detection now evaluates overnight low-HR saved sessions as gap-bounded clusters instead of treating an interrupted night as all-or-nothing. The aggregate path requires at least 3 hours of total overnight low-HR evidence, splits clusters when gaps exceed 2 hours, rejects workout-like sessions, uses the cluster 5th-percentile HR for RHR, and always reports `confidence=low` with `motion_source=unavailable` until IMU/motion is decoded. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-broken-sleep-aggregate/` built, installed, launched, and logged `broken_sleep_summary candidates=1 eligible_sessions=2 ... min_total_s=10800 max_gap_s=7200` plus `broken_sleep_candidate day=2026-06-13 sessions=1 duration_s=10803 avg_hr=58 peak_hr=85 rest_hr=52 confidence=low reason=HR-only overnight low-HR window; motion not decoded`. The same run verified `daily_rollup ... workouts=0 sleep_candidates=1 hrv=learning rhr=52` and a local backup/verify of `17` sessions. Gate E still needs a real elevated-HR workout captured and detected on device before the full gate passes.

**Phase E update 2026-06-14 interrupted-sleep fallback:** the June 14 post-wake
store contained a broken sleep pattern: two low-HR chunks totaling `10545s`
inside a `13706s` overnight span, separated by a wake/interruption gap, while a
high-HR chunk was correctly excluded. The aggregate detector now keeps the
strict `10800s` low-HR rule but also accepts a labeled low-confidence fallback
for interrupted nights when low-HR evidence is at least `9000s`, the overnight
span is at least `10800s`, and cluster gaps remain below `7200s`. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T133632Z-fragmented-sleep-fallback-device-verify/`
logged `broken_sleep_summary candidates=2 ... fragmented_min_total_s=9000
fragmented_min_span_s=10800`, `broken_sleep_candidate day=2026-06-14
sessions=2 duration_s=10545 span_s=13706 max_gap_s=3161 avg_hr=60 peak_hr=102
confidence=low`, and daily rollups with `sleep_candidates=1` for both
2026-06-13 and 2026-06-14. Gate E remains partial because sleep is still
HR-only/low-confidence and the real workout remains a near miss
(`workout_days=0`, `workout_best_blocker=stream_gaps`).

**Phase E update 2026-06-14 aggregate sleep validation:** `--verify-sleep`
now reports the newest aggregate sleep candidate when no label is supplied,
instead of sorting only single saved sessions by duration. This keeps the
diagnostic aligned with daily rollups for interrupted nights. Physical iPhone
evidence in
`docs/evidence/gate-e/20260614T134015Z-aggregate-sleep-validation-device-verify/`
logged `sleep_validation status=ready reason=aggregate_overnight_low_hr_window
matched_label=aggregate_sleep_2_chunks source=aggregate_sleep duration_s=10545
span_s=13706 max_gap_s=3161 samples=6249 avg_hr=60 peak_hr=102 confidence=low`
plus `gate_status gate=E ... sleep_days=2 ... workout_days=0`. This is still
not a Gate E exit because sleep confidence remains HR-only and workout
auto-detection has not produced a ready workout.

**Phase E update 2026-06-14 historical motion overlap:** the app now evaluates
historical `0x2f` gravity rows against each aggregate sleep window before using
them as sleep motion evidence. The rule is fail-closed: rows must overlap the
candidate timestamps, be gravity-validated, cover at least 30 minutes, and pass
low vector/magnitude variance thresholds before sleep confidence can rise above
HR-only. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T161704Z-historical-motion-overlap-device-verify/`
built, installed, launched, and logged both overnight candidates with
`historical_motion_status=learning`,
`historical_motion_reason=no_timestamp_overlap`, `historical_motion_rows=0`,
and `historical_motion_validated=0`. The same run showed the archive is real
but not usable for those sleep windows:
`historical_archive_rows=350`, `historical_archive_gravity_rows=350`,
`historical_archive_gravity_validated_rows=350`,
`historical_archive_metric_usable=0`, and `historical_archive_current_usable=0`.
So the prior "motion not decoded" blocker is now more precise: historical
gravity exists, but the downloaded rows do not timestamp-align with saved sleep
or workout windows yet. Gate E remains partial with `sleep_days=2`,
`sleep_state=low_confidence`, `workout_days=0`, and the workout still blocked by
insufficient sustained elevated HR.

**Phase E update 2026-06-14 historical motion separation:** the sleep motion
diagnostic now logs the historical archive timestamp range and nearest
separation from the candidate sleep window, so non-overlap can be ruled out on
device without manual archive inspection. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T162055Z-historical-motion-separation-device-verify/`
built, installed, launched, and logged the June 14 aggregate sleep candidate
with `historical_motion_archive_first_unix=1774825626`,
`historical_motion_archive_last_unix=1774825923`, and
`historical_motion_nearest_separation_s=6572898`. The June 13 candidate logged
`historical_motion_nearest_separation_s=6481756`. This proves the current
downloaded gravity block is old stored history, not merely a missing drift
correction, so captured-at time must not be used as a surrogate motion
timestamp. Sleep remains low-confidence and Gate E remains partial.

**Phase E update 2026-06-13 workout auto-save guard:** the app and launcher now support `--auto-save-workout-when-ready N` / `--whoop-auto-save-workout-when-ready N`, which checks the current live session at an interval and saves it only when the existing sustained-workout readiness gate passes. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-gate-e-workout-auto-save-guard/` built, installed, launched, and logged the guard schedule plus repeated honest refusals at wake/rest HR: `workout_auto_save status=learning reason=not_ready ... duration_s=36 avg_hr=91 peak_hr=98 ... elevated_s=0 required_elevated_s=300 longest_bout_s=0 required_bout_s=180`. The same run checkpointed the live session and the delayed verifier correctly returned `workout_validation status=learning reason=duration_below_10m ... workouts_matching=0`. This makes the next real workout attempt durable without lowering thresholds; Gate E still needs a real >=10-minute elevated-HR workout with `workout_auto_save status=saved` and `workout_validation status=ready` on the physical iPhone.

**Phase E update 2026-06-15 leave-running harness:** the cabled-device harness now
supports `--leave-running`. After the console evidence window, required pulls,
and harness validations complete, it relaunches Atria without `--console` in
safe low-radio Long wear mode (`standard_hr_only`, 60-second checkpoints,
15-minute session autosaves, 60-second workout checks). It intentionally does
not repeat one-shot debug operations such as HealthKit resets or reference
validation. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-leave-running-harness-device-verify/` built,
installed, launched, logged current gate status, pulled `sessions.json`, then
reported `HARNESS_LEAVE_RUNNING status=launched`. A follow-up process check
showed Atria still running on the phone. This is not a Gate E metric pass; it
advances the unattended-local-logging requirement and reduces the chance that
short verification runs accidentally stop the long-wear collector.

**Phase E update 2026-06-13 local status dashboard:** the main dashboard now has a `Local status` card for Sleep, Workout, HRV, and Trends, using the same local store inputs and confidence gates as `WHOOPDBG gate_status`. Physical iPhone evidence in `docs/evidence/gate-e/20260613T-local-status-dashboard/` verified `WHOOPDBG local_status ...`, `gate_status gate=local status=dashboard ...`, and the expanded Gate E evidence line. A stale-verification issue was found and fixed: `live_device_debug.sh --no-build` now refuses to run when Swift sources are newer than the project-local app bundle it installs from `build/DerivedData`, preventing accidental validation of an old binary. During that cleanup the app was uninstalled once from the physical iPhone, which reset the on-phone local session store and removed in-app backups; earlier 18-session evidence remains documented, but the current phone container is rebuilding from zero sessions. Post-reset verification completed onboarding and confirmed BLE still works (`realtime_rr_fraction=1.000` over the short smoke). Gate E remains open: the current store has no sleep/workout sessions after reset, and no real elevated-HR workout has validated.

**Phase E update 2026-06-13 workout readiness reasons:** workout readiness now
has a shared strict decision state with `status`, `reason`, and personalized
`threshold_hr`, reused by live diagnostics, auto-save, daily rollups, and saved
workout validation. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T084311Z-workout-readiness-reason-smoke/` built,
installed, launched, wrote/verified/pulled a backup, and streamed realtime RR
cleanly (`realtime_rr_fraction=1.000`, `max_rr_log_gap_s=1.2`). The detector
correctly stayed `learning` during the short resting wake-up run:
`reason=duration_below_10m`, `duration_s=57`, `avg_hr=75`, `peak_hr=79`,
`threshold_hr=133`, `elevated_s=0`. Gate E remains partial: the current store is
empty after reset (`sessions=0`), and a real sustained elevated-HR workout still
must be captured on device.

**Phase E update 2026-06-13 post-wake store audit + default checkpoint:** after
adidshaft's interrupted overnight wear, `docs/evidence/gate-e/20260613T093848Z-postwake-current-store-audit/`
rebuilt, installed, launched, and audited the current physical-iPhone store. The
store contained only `sessions=2`, `sleep_days=0`, `workout_days=0`, and
`duration_s=24`, proving the long foreground wear had not persisted a durable
session after the app-container reset. The app now schedules a default foreground
`Unattended checkpoint` every `300s` whenever no explicit session-persistence
launch argument is present. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T094133Z-default-foreground-checkpoint/` verified
the schedule log and the first saved checkpoint:
`samples=308 duration_s=297 avg_hr=61 peak_hr=86 resting_hr=57 hrv=learning
source=default_foreground`, with an automatic backup pulled from the device. This
fixes unattended foreground data loss for the next long wear run, but Gate E
remains partial until fresh saved history produces sleep/workout detections on
device. HRV remains reference-pending (`hrv_ready=False`; no external RR/IBI
reference).

**Phase E update 2026-06-13 current-store sleep rollup audit:** `docs/evidence/gate-e/20260613T115456Z-current-store-sleep-rollup-audit/`
ran on the cabled physical iPhone after the post-reset store had rebuilt to
`8` short sessions. The app correctly logged `sleep_candidates=0`,
`workouts=0`, and `broken_sleep_summary ... rejected_too_short=8`; the sleep
verifier stayed `learning` with `reason=duration_below_3h` on the latest
`597s` checkpoint. Backup write/verify/pull succeeded for the current store
(`sessions=8`, `digest_match=1`) and BLE still streamed in the same launch
(`realtime_rr_fraction=0.833`). This confirms the current miss is missing
durable long-session state after the earlier app-container reset, not a reason
to loosen detection thresholds. Next recovery step is a Mac-side tool that
reconstructs a restorable session backup from the real overnight WHOOPDBG log
and restores it on the physical iPhone.

**Phase E update 2026-06-13 reconstructed sleep backup restore:** `tools/reconstruct_session_backup_from_log.py`
now rebuilds a local `SessionBackupEnvelope` from real `WHOOPDBG realtimeFrame`
rows, copying baseline/profile from a current backup and forcing
`hrvReferenceValidated=false`. Smoke evidence in
`docs/evidence/gate-e/20260613T120002Z-reconstructed-sleep-backup-smoke/`
created a `9`-session backup with `11236` real HR samples over `10800.704s`
for `gate-e-overnight-checkpoint-run` and `hrv=null`. Physical iPhone evidence
in `docs/evidence/gate-e/20260613T120151Z-restore-reconstructed-sleep-backup-clean/`
restored that backup and logged `sleep_validation status=ready ... duration_s=10801 samples=11236 ... confidence=low`,
with `hrv_state=reference_pending`. A failed first attempt in
`docs/evidence/gate-e/20260613T120038Z-restore-reconstructed-sleep-backup/`
exposed a launch-order race where `--backup-sessions --restore-backup` could
write a newer debug backup before restore; the app now restores before
launch-time backup/write/verify diagnostics. Follow-up physical iPhone evidence
in `docs/evidence/gate-e/20260613T120319Z-restore-order-and-current-backup-verify/`
and `docs/evidence/gate-e/20260613T120432Z-backup-selector-restored-store-verify/`
verified the restored store, ordinary-backup selection, `backup_current=1`,
`daily_rollup ... sessions=9 workouts=0 sleep_candidates=1 ... hrv=learning rhr=52`,
and `gate_status gate=E ... sleep_days=1 ... workout_days=0 ... hrv_state=reference_pending`.
Gate E remains partial because no real elevated-HR workout has passed and sleep
is still low-confidence HR-only until motion/IMU is decoded.

**Phase E update 2026-06-13 live workout status diagnostic:** the dashboard
`Local status` card and `WHOOPDBG local_status` log now include the current live
session's sustained-workout readiness: duration, average/peak HR, personalized
threshold, elevated seconds, longest elevated bout, required seconds/bout, ready
flag, and reason. A first build attempt in
`docs/evidence/gate-e/20260613T120918Z-live-workout-status-diagnostic/` failed on
field names and was fixed before verification. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T120938Z-live-workout-status-diagnostic-verify/`
built, installed, launched, and logged the restored store as `daily_rollup ...
sessions=9 workouts=0 sleep_candidates=1 ... hrv=learning rhr=52`. The live
resting attempt stayed honest: `live_workout ... reason=duration_below_10m
samples=77 duration_s=73 avg_hr=72 peak_hr=77 threshold_hr=133 elevated_s=0
required_elevated_s=300 longest_bout_s=0 required_bout_s=180 ready=0`, repeated
by `workout_auto_save status=learning`; delayed verification returned
`workout_validation status=learning reason=no_saved_session`. This answers the
"why did it fail?" path on-device, but it is not a workout pass. Gate E still
needs a real sustained elevated-HR session that auto-saves and validates as
`status=ready`. HRV remains separate and gated (`realtime_rr_fraction=0.462`,
`hrv_ready=False`).

**Phase E update 2026-06-13 saved workout replay gate status:** Gate E launch
status now replays all saved sessions through the same sustained-workout
detector and logs the best candidate plus exact blocker. Physical iPhone
evidence in
`docs/evidence/gate-e/20260613T144200Z-workout-replay-gate-status/` built,
installed, launched, backed up, verified `digest_match=1`, and logged
`workout_replay_summary sessions=15 ready=0
best_label=gate-e-overnight-checkpoint-run status=learning
reason=elevated_seconds_below_required duration_s=10801 elevated_s=0
required_elevated_s=1200 longest_bout_s=0 required_bout_s=480`. The matching
`gate_status gate=E` line includes `workout_saved_ready=0` and
`workout_best_reason=elevated_seconds_below_required`; daily rollup still shows
`workouts=0 sleep_candidates=1`. Gate E remains incomplete until a real
sustained elevated-HR workout is captured and validates on the physical iPhone.

**Phase E update 2026-06-13 checkpoint-armed gate status:** Gate E/local status
now reports whether foreground checkpoint persistence is armed for the current
launch, including interval, source, and label. Launch automation clears stale
checkpoint diagnostics before scheduling, so an explicit non-checkpoint launch
cannot inherit an old `checkpoint_armed=1`. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T095213Z-checkpoint-armed-gate-status-clear/`
built, installed, launched, wrote/verified/pulled a backup, and logged both the
schedule line and `gate_status gate=E ... checkpoint_armed=1 ...
checkpoint_interval_s=300 ... checkpoint_source=default_foreground`. The same
short run streamed real RR (`realtime_rr_fraction=0.950`) but is not a Gate B or
Gate E pass; it proves future unattended/post-wake audits can verify persistence
readiness immediately instead of waiting for a 300-second save.

**Phase E update 2026-06-13 checkpoint last-outcome status:** checkpoint
diagnostics now retain the last checkpoint outcome across launches:
`checkpoint_last_status`, `checkpoint_last_index`, `checkpoint_last_samples`,
and `checkpoint_last_duration_s`. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T095500Z-checkpoint-last-outcome-save/` built,
installed, launched, and saved the default foreground checkpoint with
`samples=310 duration_s=297 avg_hr=68 peak_hr=85 resting_hr=59 hrv=learning`,
then pulled the automatic checkpoint backup. RR continuity degraded during that
run (`realtime_rr_fraction=0.552`, `hrv_ready=False`), so HRV correctly stayed
learning. A no-build audit relaunch in
`docs/evidence/gate-e/20260613T100046Z-checkpoint-last-outcome-gate-status/`
verified `gate_status gate=E ... checkpoint_armed=1 ... checkpoint_last_status=saved
... checkpoint_last_samples=310 ... checkpoint_last_duration_s=297`. This
closes the unattended persistence observability gap: post-wake audits can now
distinguish an armed checkpoint from a successful previous checkpoint save. Gate
E remains partial until real sleep/workout detections are present in current
history.

**Phase E update 2026-06-13 workout background collection:** before adidshaft's real
workout, the app was hardened for unattended local collection. CoreBluetooth now
uses a restoration identifier, app/store callbacks are wired at app
initialization, and live `2A37` HR notifications trigger an upsert checkpoint
every 180 seconds so background BLE delivery can persist data even when regular
timers are not reliable. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T145402Z-workout-background-collection/` built,
installed, launched, verified backup `digest_match=1`, subscribed to standard
HR and WHOOP streams, and logged `session_checkpoint schedule interval_s=180.0
label=workout-background-collection`. The short verification saw
`standard_2a37_rr_values=22` and `rr_source_0x28_used_values=0`, then the
terminating harness was replaced by a direct `devicectl` launch. The app was
confirmed running as a device process for the workout. Gate E still requires the
completed workout to validate as sustained elevated HR on device.

**Phase E update 2026-06-13 local-status checkpoint fields:** the dashboard
`Local status` card and `WHOOPDBG local_status` log now mirror checkpoint
readiness and the last checkpoint outcome, so post-wake audits can see
`checkpoint_armed`, interval, source, last status, last samples, and last
duration without relying only on `gate_status`. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T100439Z-local-status-checkpoint-fields/` built,
installed, launched, verified/pulled a backup, and logged
`local_status ... checkpoint_armed=1 checkpoint_interval_s=300
checkpoint_source=default_foreground checkpoint_last_status=saved
checkpoint_last_samples=310 checkpoint_last_duration_s=297`. Gate E remains
partial (`sleep_days=0`, `workout_days=0`) and Gate B remains reference-pending;
the short awake smoke produced `realtime_rr_fraction=0.000`, so HRV correctly
stayed learning.

**Phase E update 2026-06-14 return-store workout audit:** after adidshaft's
unattended out-of-house wear, the cabled physical iPhone store was pulled and
verified in `docs/evidence/gate-e/20260614T-return-current-store-pull/`.
The app had persisted `40` sessions and the backup verification matched the
current store digest. The newly returned workout-labeled chunks totaled `906s`
with `924` accepted `2A37` HR samples, but the best aggregate workout candidate
remained learning: `stream_coverage_percent=9`, `observed_duration_s=196`,
`dropped_gap_s=1944`, `max_gap_s=1170.2`, `peak_hr=103`,
`threshold_hr=133`, and `elevated_s=0`. This is not a missed workout pass; it
is insufficient elevated-HR evidence plus sparse stream coverage. Aggregate
workout replay/logging now carries saved HR-quality counters so future long
wear audits expose whether failure came from low captured HR, notification
gaps, zero/contact samples, or artifact filtering without loosening Gate E.
Physical iPhone verification in
`docs/evidence/gate-e/20260614T-workout-aggregate-hr-quality-device-verify/`
confirmed the new fields in `aggregate_workout_summary`,
`aggregate_workout_candidate`, `workout_readiness`, and
`workout_replay_summary`, plus `session_backup_verify status=ok` with
`digest_match=1`.

**Gate B continuity update 2026-06-13 long run:** the same overnight checkpoint run ended with `hrv_ready=True`, `rr_values=10033`, `realtime_rr_fraction=0.868`, and analyzer output found `13` Gate-B-ready 300s RR windows. Best analyzer window: `05:31:51.772` to `05:36:51.772`, `raw=292`, `kept=291`, `conf=99.7`, `max_gap_s=2.011`, `rmssd_ms=60.5`, `sdnn_ms=76.5`, `pnn50=41.7`, `lnrmssd=4.102`. This clears the live-continuity blocker under tight-wear overnight conditions. Gate B is still not fully passed until RMSSD is compared against an external RR/IBI reference within `+/-5 ms`.

**Gate B post-reset update 2026-06-13 fresh 5-minute attempt:** after the app
container reset, `docs/evidence/gate-b/20260613T082800Z-fresh-5min-rr-backup/`
ran a new physical-iPhone 300s RR gate with backup write/verify and Mac-side
backup pull enabled. The run built, installed, launched, and copied the backup
JSON, but did not pass Gate B: whole-run `realtime_rr_fraction=0.887`, final
auto-capture `fraction=0.879`, `max_rr_gap_s=31.7`, and final HRV correction
`raw=371 kept=49 conf=13 reason=gap`. `hrv_ready=False`, so metrics correctly
stayed `learning` and the launcher exited status `2` from `--until-ready`. This
does not contradict the earlier overnight clean-window evidence; it proves the
current post-reset awake stream remains contact/strap-confidence sensitive and
below the 5-minute clinical bar.

**Gate B diagnostic update 2026-06-13 RR-byte logger honesty:** `rrBytes` logging
now contains only the declared `rrnum * 2` interval bytes, and fixed trailing
payload bytes are logged separately as `payloadTail`. Physical iPhone smoke
evidence in `docs/evidence/gate-b/20260613T083436Z-rrbytes-log-smoke/` verified
zero-RR frames now log `rrBytes=` and `payloadTail=00000000000000000101`; the
launcher summary reports `realtime_zero_rr_tail_nonzero_frames=0`. This avoids
misreading fixed trailer bytes as hidden RR intervals and preserves the same
strict HRV gating.

**Gate B/E update 2026-06-13 RR ledger checkpoint fallback:** saved local sessions
now include optional `rrPoints` containing every real decoded RR/IBI interval the
iPhone receives from WHOOP realtime `0x28` frames. Session save, checkpoint, and
backup logs now include `rr_samples`, and RR-quality capture aborts checkpoint the
current session before finishing the learning capture. Physical iPhone evidence
in `docs/evidence/gate-b/20260613T121643Z-rr-ledger-checkpoint-verify/` built,
installed, launched, checkpointed every 30s, verified backup decoding, and pulled
the latest backup. The run started with existing restored history at `sessions=9
rr_samples=0`, then saved growing checkpoints with `rr_samples=27`, `61`, and
`96`; the pulled backup contains `10` sessions and `96` total RR points in the
newest session. The realtime stream was clean in this short window
(`realtime_rr_fraction=1.000`, `rr_values=98`, `max_rr_log_gap_s=1.7`) but still
not Gate-B complete (`hrv_ready=False`) because it was not a 5-minute validated
window and has no external RR/IBI reference. This implements the honest
phone-side "store chunks and use later" fallback: preserve real RR that iOS
receives, never synthesize missing RR from HR-only frames, and keep metrics in
`learning` until the clinical gates pass.

**Gate B update 2026-06-13 RR-ledger 300s attempt:** a fresh physical-iPhone
300-second attempt in
`docs/evidence/gate-b/20260613T122010Z-rr-ledger-fresh-300s-attempt/` verified
the RR ledger under a real failure. Auto-capture started from a strong short
window (`reason=rr_fraction_0.957`) but correctly aborted on
`rr_gap_over_3s` before surfacing HRV. The capture summary stayed learning:
`ready=0 stop=rr_quality_abort elapsed=195 raw=228 kept=221 conf=97 window=191
max_rr_gap_s=2.6 reason=rr_gap_over_3s`. Checkpoints and the pulled backup still
preserved the received chunks: final checkpoint `samples=375 rr_samples=311
duration_s=359 hrv=learning`, final backup `sessions=11 rr_samples=407`, and
the labeled session contains `311` real RR points with
`hrvReferenceValidated=false`. Whole-run live continuity was
`realtime_rr_fraction=0.686` with `max_rr_log_gap_s=44.7` and no historical
`0x2f` frames. Conclusion: local storage/chunks are implemented and durable, but
they cannot create a Gate-B 5-minute window when the strap sends HR-only
`rrnum=0` gaps; HRV remains `learning` until a continuous live window or decoded
stored-session window passes plus external reference validation.

**Gate B update 2026-06-13 saved RR replay status:** saved RR-ledger replay is
now part of launch gate-status diagnostics. Physical iPhone evidence in
`docs/evidence/gate-b/20260613T143600Z-rr-ledger-replay-status-device-verify/`
built, installed, launched, backed up, verified `digest_match=1`, and logged
`rr_ledger_summary sessions=4 rr_samples=1298 best_ready=1 raw=347 kept=317
conf=91 window=300 max_rr_gap_s=2.8 reference_validated=0 rmssd=46.0`.
`gate_status gate=B` stayed `reference_pending` with `saved_rr_ready=1` and
`external_rr_reference_required=1`. The same live minute had HR but no fresh RR
(`standard_2a37_rr_values=0`, `realtime_rr_fraction=0.000`, `hrv_ready=False`),
so this is durable real-RR replay evidence, not a new live HRV or clinical
Gate B pass.

**Phase E update 2026-06-13 postwake baseline audit:** current-device postwake
evidence in
`docs/evidence/gate-e/20260613T134422Z-postwake-current-device-audit/` verified
the restored overnight sleep candidate (`sleep_validation status=ready ...
duration_s=10801`), local backup integrity (`digest_match=1`), and live `2A37`
RR continuity (`standard_2a37_rr_frames=94`, `realtime_rr_fraction=1.000`).
The same audit found the polluted learned baseline (`restingHR=78.75`) while the
sleep-derived daily RHR was `52`, leading to the conservative Gate D baseline
repair. Gate E remains partial: sleep exists as a low-confidence HR-only
candidate, but workout auto-detect still needs a real elevated-HR capture.

**Phase F — Trends & insights.** 7/30/90-day Recovery/HRV/RHR/Strain with anomaly flags.

**Phase F update 2026-06-13 trend slice:** History now renders 7/30/90-day local trend windows for Recovery, HRV, RHR, and Strain from saved sessions. HRV remains `learning` when no validated saved RMSSD exists; anomalies require at least 3 sessions and flag only high RHR or Strain outliers. The cabled-device debug launcher supports `--log-trends` and the app logs `WHOOPDBG trend_summary ...` plus one `trend_window` row per window. This is a Gate F slice, not the full exit, because real long-term history still has to accumulate and render across 7/30/90 days.

**Phase F update 2026-06-13 current-history refresh:** after the overnight checkpoint run created a real saved HRV/sleep session, `docs/evidence/gate-f/20260613T-gate-f-current-history-trends/` verified trends again on the physical iPhone. The app logged `trend_summary sessions=13 rest_hr=67 max_hr=191 windows=3`, and 7/30/90-day windows now include `recovery=75`, `hrv=73`, `rhr=66`, `strain=0.0`, `anomalies=0`. The same run logged the current daily rollup (`2026-06-13 sessions=10 workouts=0 sleep_candidates=1 duration_s=11016 hrv=73 rhr=53`). Gate F is still not complete because all windows are populated by sparse same-day history; validating true 7/30/90-day trend behavior requires real saved history over those spans.

**Phase F update 2026-06-13 coverage confidence slice:** Trend windows now expose covered calendar days, coverage percent, and a confidence label in both History UI and `WHOOPDBG trend_window` logs so sparse data cannot masquerade as mature 7/30/90-day trends. Physical iPhone evidence in `docs/evidence/gate-f/20260613T-gate-f-trend-coverage-confidence/` logged `days=7 coverage_days=2 coverage_percent=29 confidence=partial`, `days=30 coverage_days=2 coverage_percent=7 confidence=learning`, and `days=90 coverage_days=2 coverage_percent=2 confidence=learning`, while HRV remained `learning` and the widget stayed `hrv=reference_pending`. This improves Gate F honesty but does not complete the gate until real local history spans 7/30/90 days.

**Phase F update 2026-06-13 anomaly flag logging:** Trend windows now log the exact anomaly labels as `anomaly_flags=...` rather than only an integer count, preserving `none` when no flag fires. Physical iPhone evidence in `docs/evidence/gate-f/20260613T-gate-f-trend-anomaly-flags/` built, installed, and launched against the real saved store (`sessions=16`). The run logged `days=7 coverage_days=2 coverage_percent=29 confidence=partial recovery=74 hrv=learning rhr=65 strain=0.1 anomalies=0 anomaly_flags=none`, plus 30/90-day windows at `confidence=learning` with `anomaly_flags=none`. Live RR was zero in this short launch, so this is trend evidence only. Gate F remains incomplete until real local history spans the requested 7/30/90-day windows.

**Phase F update 2026-06-13 Recovery trend reference guard:** trend windows now average Recovery only when `recoveryV2` is high-confidence/reference-backed. The 2026-06-14 strict Recovery learning update extends that guard to the current dashboard/widget: RHR-only Recovery no longer appears as a numeric current value while HRV is reference-pending. Physical iPhone evidence in `docs/evidence/gate-f/20260613T-gate-f-recovery-trend-reference-guard/` built, installed, launched, and logged `baseline_maturity ... hrv_validated_samples=0 ... recovery_high_ready=0`; all 7/30/90 trend windows reported `recovery=learning hrv=learning`, while the older widget behavior separately logged the now-removed `recovery=75 confidence=fallback hrv=reference_pending`. Gate F remains incomplete until there is enough real saved, validated history for high-confidence trend windows.

**Phase F update 2026-06-13 RHR evidence filter:** trend RHR now uses the same
accepted baseline-learning evidence as the learned resting baseline instead of
averaging every short diagnostic session. Physical iPhone evidence in
`docs/evidence/gate-f/20260613T135029Z-trend-rhr-evidence-filter-device-verify/`
logged stable rebuilt baseline (`old_rest=52 new_rest=52`), daily rollup
`rhr=52`, and 7/30/90 trend windows all reporting `rhr=52` with backup
`digest_match=1`. Gate F remains incomplete until real local history spans the
requested windows and HRV has reference-validated history.

**Phase F update 2026-06-14 dashboard trend charts:** the dashboard now renders
a compact 7/30/90 trend card, and the shared trend view includes coverage plus
Recovery, HRV, RHR, and Strain chart surfaces. Missing Recovery/HRV values are
shown as `learning` placeholders and are not plotted as zeroes. Physical iPhone
evidence in
`docs/evidence/gate-f/20260614T-trend-chart-dashboard-device-verify/` built,
installed, launched, and logged `WHOOPDBG trend_chart_ui windows=7d,30d,90d
recovery_points=0 hrv_points=0 rhr_points=3 strain_points=3 coverage_min=2
confidence=partial,learning,learning`. The same run logged 7/30/90 trend
windows from the real saved store (`sessions=76`, `coverage_days=2`,
`coverage_percent=29/7/2`) with HRV/Recovery still `learning` and
`anomaly_flags=RHR_elevated`. Gate F remains learning because true long-range
history and reference-validated HRV are still absent.

**Phase F update 2026-06-14 blocker explainability:** Gate F status now reports
the exact trend blockers in the on-device `WHOOPDBG gate_status gate=F` row:
90-day coverage days/percent, required coverage days, window sessions, per-metric
point presence, anomaly flags, HRV reference gating, and
`trend_blockers=...`. The chart UI log now mirrors anomaly flags and blockers.
This is designed to stop trend work from looping on a generic `learning` label;
the app must say whether the blocker is sparse local history, missing external
HRV reference validation, missing Recovery points, or missing HRV points.
Physical iPhone evidence in
`docs/evidence/gate-f/20260614T-trend-blocker-explainability-device-verify/`
built, installed, launched full-protocol, confirmed BLE notify/START/CMD_RESP,
and logged `trend_blockers=coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`
with `trend90_coverage_days=2`, `trend90_coverage_percent=2`,
`trend90_recovery_points=0`, and `trend90_hrv_points=0`. Gate F remains
learning, now with an exact blocker list.

**Phase G — Platform polish.** HealthKit write, notifications, widget/complication, backup.

**Phase G update 2026-06-13 backup slice:** The app can now write a local JSON
backup of saved sessions, learned baseline, and athlete profile into
`Documents/atria-backups/`. The cabled-device debug launcher supports
`--backup-sessions`, and the app logs `WHOOPDBG session_backup ...` with the
relative path, session count, byte size, and schema. This is a local-only backup
slice, not Gate G complete: HealthKit write, notifications, widget/complication,
and restore/import still need physical-device verification. Legacy
`Documents/whoop-backups/` files remain readable for restore/verify.

**Phase G update 2026-06-13 backup verification slice:** The app can now decode
the latest local backup on-device with `--verify-backup`, check schema/session
counts against the current store, and log `WHOOPDBG session_backup_verify ...`.
This proves backup files are readable after write; destructive restore/import is
still pending and must be tested separately before backup is considered complete.

**Phase G update 2026-06-13 backup restore slice:** The app now has a guarded
debug restore path (`--restore-backup`) that writes a pre-restore safety backup,
decodes the latest local backup, restores sessions, baseline, and athlete
profile into their normal local stores, saves them, and logs
`WHOOPDBG session_backup_restore ...`. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T-gate-g-backup-restore-smoke/` verified restore
status `ok`, then a relaunch `--verify-backup` confirmed the restored store still
matched the latest backup. This closes local backup write/decode/restore
integrity; Gate G still needs HealthKit entitlement-backed write,
widget/complication, and notification delivery verification.

**Phase G update 2026-06-13 HealthKit exporter slice:** A guarded HealthKit
exporter now prepares real saved heart-rate samples and workouts, and only writes
HRV samples when a saved session has positive validated HRV. The cabled-device
debug launcher supports `--healthkit-export`. Attempting to enable the
HealthKit entitlement failed the build because the current development
provisioning profile does not include the HealthKit capability, so the app keeps
the entitlement disabled, checks the embedded provisioning profile at runtime,
and logs `WHOOPDBG healthkit_export status=missing_entitlement ...` instead of
calling HealthKit or fabricating success. Gate G HealthKit remains incomplete
until the app is signed with HealthKit enabled, permission is granted on the
physical iPhone, and HR/workout data appears in Apple Health.

**Phase G update 2026-06-14 HealthKit profile blocker recheck:** wiring the
existing `WhoopApp.entitlements` file into the target again failed the
physical-iPhone build because the automatic `iOS Team Provisioning Profile: *`
does not include the HealthKit capability or
`com.apple.developer.healthkit`. Evidence is in
`docs/evidence/gate-g/20260614T-healthkit-profile-blocker-recheck/`. The target
was restored to the default buildable configuration and the same physical-iPhone
destination then reached `BUILD SUCCEEDED`. Gate G remains partial for an
external Apple signing-profile reason, not because the app lacks an exporter.

**Phase G update 2026-06-14 entitlement/app-group verification:** the widget
now renders the published snapshot model and can read it from
`group.com.adidshaft.atria` once an app-group entitlement is provisioned. The repo
also carries explicit app/widget entitlement templates for the required
HealthKit + shared app-group capabilities. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T-gate-g-entitlements-device-verify/` tried
wiring those entitlements and Xcode rejected the automatic wildcard profile:
HealthKit is missing, and app groups were refused for both app and widget. The
default target was restored to keep builds green, then rebuilt/installed/launched
on the cabled iPhone. Runtime logs showed `healthkit_export
status=missing_entitlement`, `widget_snapshot status=ok`, `widget_target=1`,
`complication_target=1`, and `storage=app_local_userdefaults app_group=0`.
Gate G remains partial until an explicit Apple profile/App ID includes
HealthKit and `group.com.adidshaft.atria`, then the same device flow can verify
`healthkit_export status=saved` and shared widget storage.

**Phase G update 2026-06-14 Atria HealthKit export verified:** the product/app
name is now Atria with explicit Apple identifiers `com.adidshaft.atria`,
`com.adidshaft.atria.widget`, and target app group `group.com.adidshaft.atria`.
Manual development profiles were installed for the app and widget. The app
profile includes HealthKit; the downloaded profiles do not include app groups
because the Apple Developer app-group assignment did not persist, so app-group
entitlements are intentionally omitted until the portal/profile state is fixed.
After the user granted Apple Health write permission on the cabled physical
iPhone, `docs/evidence/gate-g/20260614T-gate-g-atria-healthkit-export-device-verify/`
logged `healthkit_export status=saved sessions=84 hr_samples=40672 workouts=84
hrv_samples=0` from `Atria.app`. The export skipped zero-duration HR samples
instead of creating invalid HealthKit samples, and still wrote no HRV because
Gate B reference validation is missing. Gate G remains partial: HealthKit
HR/workout write is physically verified, but shared widget/app-group storage is
diagnostic-only (`widget_app_group=0`) and final user-visible Apple Health/widget
surface checks remain to be closed.

**Phase G update 2026-06-14 Health write permission reverify:** after Health
write access was granted again, the physical iPhone run in
`docs/evidence/gate-g/20260614T111819Z-healthkit-write-permission-saved-retry/`
rebuilt, installed, launched, and logged `healthkit_export status=saved
sessions=86 hr_samples=40906 workouts=86 hrv_samples=0`. Gate G readiness now
shows the remaining platform blocker as `G=partial[app_group]`: HealthKit
entitlement and write are working, HRV export stays zero by Gate B reference
policy, and shared widget storage still requires App Group provisioning.

**Phase G update 2026-06-14 current HealthKit permission reverify:** after the
latest Health write permission grant, the bounded export run in
`docs/evidence/gate-g/20260614T124249Z-bounded-rr-export-healthkit-device-verify/`
rebuilt, installed, launched on the cabled iPhone, and logged
`healthkit_export status=saved sessions=96 hr_samples=42198 workouts=0 hrv_samples=0`.
This confirms Apple Health write is active with the fail-closed workout/HRV
policy. The same run pulled HR and RR reference packages; their same-file
validator smokes were parser-only (`external_reference=0`), so Gate D and Gate B
remain externally reference-gated.

**Phase D/G update 2026-06-14 HealthKit reference audit:** HealthKit export now
also performs a non-prompting independent-HR audit. It checks whether heart-rate
read access is already available and, only if it is, counts non-Atria HR samples
in the saved-session time span while excluding samples with Atria metadata or
the Atria bundle ID. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T125246Z-healthkit-reference-audit-device-verify/`
built, installed, launched, kept HealthKit write working
(`healthkit_export status=saved sessions=99 hr_samples=42503 workouts=0 hrv_samples=0`),
and logged
`healthkit_reference_audit status=read_permission_required request_status=should_request external_reference_ready=0`.
This opens a local Apple Health path for Gate D reference comparison, but it is
not a Gate D pass: heart-rate read permission and independent non-Atria HR
samples are still required before `validate_hr_reference.py` can prove `+/-2 bpm`.

**Phase G/D update 2026-06-14 Health write recheck:** after the user granted
Apple Health write permission again, the cabled iPhone re-run in
`docs/evidence/gate-g/20260614T125607Z-healthkit-write-permission-rerun/`
rebuilt, installed, launched, exported the HR reference package, and logged
`healthkit_export status=saved sessions=100 hr_samples=42541 workouts=0 hrv_samples=0`.
The independent-reference audit still logged
`healthkit_reference_audit status=read_permission_required request_status=should_request external_reference_ready=0`.
Conclusion: HealthKit write is working and Gate G remains ready, but Gate D is
still partial because Apple Health heart-rate read access, plus independent
non-Atria HR samples, is required before Apple Health can serve as a local
reference.

**Phase D/G update 2026-06-14 Health read request:** the HealthKit export path
now requests `heartRate` read access alongside HR/HRV/workout write access, then
runs the independent-reference audit only after the authorization callback. The
physical iPhone run in
`docs/evidence/gate-d/20260614T125832Z-healthkit-read-request-device-verify/`
installed the patched build and logged
`healthkit_export status=authorization_requested sessions=101 hr_samples=42681 workouts=0 hrv_samples=0 read_hr=1`.
The run continued streaming live HR, but HealthKit did not return the callback
before the harness terminated, consistent with an on-device permission sheet
awaiting the read grant. This is a code-path fix, not a Gate D pass; the next
recheck must show either `healthkit_reference_audit status=ok ... independent_hr_samples>0`
or a continued permission denial.

**Phase D/G update 2026-06-14 Health read available, no independent reference:**
the next cabled iPhone run in
`docs/evidence/gate-d/20260614T130159Z-healthkit-auth-watchdog-device-verify/`
rebuilt, installed, launched, kept live `2A37` streaming, requested HealthKit
with `read_hr=1`, saved HealthKit HR (`healthkit_export status=saved sessions=102 hr_samples=42646 workouts=0 hrv_samples=0`),
and completed the independent-reference audit:
`healthkit_reference_audit status=ok total_hr_samples=375677 atria_hr_samples=375677 independent_hr_samples=0 independent_sources=none external_reference_ready=0`.
This rules out HealthKit permission as the immediate blocker and replaces it
with a cleaner one: Apple Health has no independent non-Atria HR samples in the
matching window. Gate D remains partial until a non-Atria reference source is
present and `validate_hr_reference.py` proves `+/-2 bpm`.

**Phase D update 2026-06-14 Health reference state in Gate D:** the HealthKit
reference audit is now persisted locally and included in Gate D diagnostics.
Physical iPhone evidence in
`docs/evidence/gate-d/20260614T130658Z-healthkit-reference-state-gate-status-device-verify/`
ran the export/audit path, then relaunched with `--log-gate-status`. The audit
logged `total_hr_samples=418323 atria_hr_samples=418323 independent_hr_samples=0`,
and Gate D now reports
`primary_blocker=independent_non_atria_hr_reference_missing`,
`healthkit_reference_status=ok`, `healthkit_independent_hr_samples=0`, and
`healthkit_external_reference_ready=0`. This does not pass Gate D, but it makes
the blocker exact and visible in both `WHOOPDBG gate_status gate=D` and the
in-app readiness strip.

**Phase G update 2026-06-14 Atria app-group profile recheck:** current App
Group blocker is confirmed against the explicit Atria profiles. In
`docs/evidence/gate-g/20260614T-atria-app-group-profile-recheck/`, the app and
widget entitlements were temporarily wired to
`group.com.adidshaft.atria` and rebuilt for the physical iPhone. Xcode failed
with exit 65 because `Atria App Development` and `Atria Development` do not
support the group and do not match the `com.apple.security.application-groups`
entitlement; profile inspection shows `app_groups=[]` for both. After restoring
the fail-closed entitlements, Atria rebuilt, installed, and launched on the
cabled iPhone. Runtime Gate G stayed partial with `healthkit_entitlement=present`,
`widget_target=1`, `complication_target=1`, and `widget_app_group=0`. The next
Gate G action is not code: regenerate/install app and widget profiles whose App
Groups arrays include `group.com.adidshaft.atria`, then re-enable the entitlement
and verify shared widget storage on device.

**Phase G update 2026-06-14 automatic signing ruled out:** the bounded Xcode
managed-profile attempt in
`docs/evidence/gate-g/20260614T-app-group-xcode-managed-profile-attempt/`
temporarily added the App Group entitlement and switched the targets to
automatic signing with `-allowProvisioningUpdates`. Xcode failed because no
developer account is configured in local Xcode accounts, fell back to
`iOS Team Provisioning Profile: *`, and that wildcard profile lacks HealthKit,
App Groups, and `group.com.adidshaft.atria`. The project was restored to manual
signing, then rebuilt, installed, and launched on the physical iPhone with
`widget_app_group=0`. Do not keep retrying shell automatic signing; the remaining
Gate G action is portal/profile repair for the concrete app group.

**Phase G update 2026-06-14 Gate G ready:** the App Group profile blocker was
repaired through Apple Developer in Chrome. `com.adidshaft.atria` and
`com.adidshaft.atria.widget` were assigned `group.com.adidshaft.atria`; Apple
invalidated the old profiles; regenerated app/widget profiles were downloaded to
`~/Documents/keys/atria-profiles` and installed into Xcode's
profile cache. `docs/evidence/gate-g/20260614T113817Z-atria-app-group-ready-status-device-verify/`
rebuilt, installed, and launched on the cabled iPhone. The app signed with
`Atria App Development` UUID `e1b67d88-b48a-4225-bec8-a869f6214e5a`; the widget
signed with `Atria Development` UUID `b65d5f19-f60c-43cc-9534-5f5cd57f3866`.
Runtime logs now show `gate_status gate=G status=ready`,
`widget_storage=app_group_userdefaults`, `widget_app_group=1`,
`widget_target=1`, `complication_target=1`, `app_group_widget=shared_ready`, and
`widget_readiness status=ready`. HRV export remains zero by Gate B reference
policy. Gate G platform plumbing is physically verified ready.

**Phase G update 2026-06-14 HealthKit idempotency:** repeated pre-ledger
HealthKit export probes polluted Apple Health with duplicate Atria-owned HR
samples (`healthkit_reference_audit total_hr_samples=461000`,
`atria_hr_samples=461000`, `independent_hr_samples=0`). A broad metadata-delete
cleanup path was built and tested but did not complete inside the physical
iPhone debug window, so the exporter now uses a local incremental export ledger:
cached HealthKit write authorization bypasses the prompt path, an existing
Atria-owned HealthKit population seeds the ledger, and future runs write only
new HR points/eligible workouts/reference-validated HRV. Physical-device
evidence in
`docs/evidence/gate-g/20260614T132128Z-healthkit-ledger-seed-device-verify/`
logged `healthkit_export status=skipped_existing_atria_samples ... ledger_seeded=1
idempotent=1`; the immediate follow-up in
`docs/evidence/gate-g/20260614T132229Z-healthkit-ledger-incremental-device-verify/`
logged `healthkit_export status=authorization_cached ... hr_samples=1` and then
`healthkit_export status=up_to_date ... ledger_entries=105 idempotent=1`. This
prevents further duplicate floods but does not delete legacy duplicates already
visible in Apple Health. Gate D still excludes Atria-owned HealthKit samples and
remains partial until an independent non-Atria HR reference exists.

**Phase G update 2026-06-14 HealthKit writable-count alignment:** the HealthKit
export planner now counts only points the writer can legally save: positive BPM
with a non-empty sample interval before the session end. This closes a false
delta where terminal points were counted in the plan but skipped by the writer.
The cabled physical iPhone run in
`docs/evidence/gate-g/20260614T132920Z-healthkit-ledger-writable-count-device-verify/`
verified the fix with matching plan/write counts:
`healthkit_export status=authorization_cached ... hr_samples=44`, followed by
`healthkit_export status=saved ... hr_samples=44 ... incremental=1`.

**Phase G update 2026-06-13 backup digest verification:** Local backup
write/verify/restore diagnostics now include a deterministic SHA-256 content
digest over schema, app id, sessions, learned baseline, and athlete profile
while excluding the backup timestamp. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T-gate-g-backup-digest-verify/` built, installed,
launched, wrote `17` saved sessions to backup, and verified
`session_backup_verify status=ok ... digest_match=1` with identical backup and
current-store digests. The same run kept the widget snapshot honest
(`confidence=fallback`, `hrv=reference_pending`, `app_group=0`) and had only
`realtime_rr_fraction=0.103`, so it is backup evidence only. Gate G remains
incomplete until entitlement-backed HealthKit writes, notification delivery, and
real widget/complication surfaces are verified on the physical iPhone.

**Phase G update 2026-06-13 Mac-side backup pull:** The cabled-device launcher
now supports `--pull-backups DIR`. During a physical iPhone run it records the
exact `WHOOPDBG session_backup path=...` file produced by `--backup-sessions`
and copies that JSON out of the app data container with `devicectl`, logging
`WHOOPDBG_BACKUP_PULL_FILE=...`. Evidence in
`docs/evidence/gate-g/20260613T082612Z-device-backup-pull/` built, installed,
launched, wrote and verified a backup, copied
`whoop-sessions-20260613T082619Z-debug.json` to the Mac, and validated that the
pulled JSON is readable. This run reflects the post-reset phone store
(`sessions=0`, `profile_max_hr=190`, `baseline_samples=0`); it proves backup
egress safety for future unattended runs, not recovery of the earlier overnight
sessions. The short smoke also showed BLE was alive
(`realtime_rr_fraction=1.000`, max RR log gap `1.1s` over 11 realtime frames).

**Phase G update 2026-06-13 Mac-side backup push/restore:** The cabled-device
launcher now supports `--push-backup PATH`, validates the Mac-side JSON, copies
it into `Documents/atria-backups/` in the iPhone app container, and can then run
the existing on-device `--verify-backup` and `--restore-backup` gates against
that imported file. Restore now ignores `*-pre-restore.json` safety backups as
restore sources and selects backups by timestamped filename, avoiding stale file
modification-time behavior from `devicectl`. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T085226Z-mac-backup-push-restore-direct/`
verified the original legacy path
`WHOOPDBG_BACKUP_PUSH_FILE=Documents/whoop-backups/whoop-sessions-20260613T085230Z-pushed.json`,
`session_backup_verify status=ok ... digest_match=1`, and
`session_backup_restore status=ok path=...pushed.json safety=...pre-restore.json`.
The input backup was still a post-reset zero-session backup, so this proves
round-trip backup transport and restore integrity for future captures, not
recovery of the earlier 18-session in-app store.

**Phase G update 2026-06-13 automatic backup on save:** Session mutations now
write an automatic local JSON backup after completed session saves, checkpoint
upserts, deletes, onboarding/profile changes, and baseline/profile updates that
matter for the backup digest. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T085710Z-auto-backup-on-save-smoke/` saved a real
short live session (`samples=15`, `duration_s=14`, `hrv=learning`), logged
`session_backup_auto status=ok reason=session-add ... sessions=1`, then
relaunched and verified the latest automatic backup with
`session_backup_verify status=ok ... sessions=1 current_sessions=1 ... digest_match=1`.
This improves unattended-capture survivability after the prior app-container
reset, but Gate G remains partial until HealthKit entitlement-backed writes,
real widget/app-group surfaces, and production notification cadence are verified.

**Phase G update 2026-06-13 verify-backup pull fallback:** The cabled-device
launcher now treats `WHOOPDBG session_backup_verify path=...` as a pullable
backup source when no new `session_backup path=...` was created in that launch.
Physical iPhone evidence in
`docs/evidence/gate-g/20260613T090232Z-verify-backup-pull-fallback/` used a
verify-only `--no-build` launch, confirmed `session_backup_verify status=ok`
with `sessions=1 current_sessions=1 digest_match=1`, emitted
`WHOOPDBG_BACKUP_FILE=...auto-session-add.json`, and pulled that exact backup
to the Mac. This makes backup evidence/recovery checks less fragile; Gate G
remains partial for HealthKit, widget/app-group, and production notifications.

**Phase G update 2026-06-13 automatic backup retention:** Automatic backups now
prune only `-auto-` backup files after each backup write, keeping the newest 24
and preserving debug, pushed, manual, and pre-restore safety files. Physical
iPhone evidence in
`docs/evidence/gate-g/20260613T090428Z-auto-backup-prune-smoke/` saved a real
short session, wrote `...T090451Z-auto-session-add.json`, logged
`session_backup_prune status=ok keep=24 kept_auto=3 deleted=0 total_json=18 auto_json=3`,
then relaunched and verified `sessions=2 current_sessions=2 digest_match=1`.
No deletion was expected because only three automatic backups existed. This keeps
checkpoint-heavy unattended runs from growing automatic backups without bound;
Gate G remains partial for HealthKit, widget/app-group, and production
notifications.

**Phase G update 2026-06-13 HealthKit preflight counts:** HealthKit export
diagnostics now compute the exact would-export payload before the entitlement
guard, so a missing provisioning capability no longer hides whether local HR,
workout, and validated-HRV data are ready. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T090803Z-healthkit-preflight-counts/` built,
installed, launched, and logged
`healthkit_export status=missing_entitlement sessions=2 hr_samples=27 workouts=2 hrv_samples=0 action=enable_healthkit_capability`.
This proves the current store can prepare HR/workout payloads while preserving
the external-reference HRV gate (`hrv_samples=0`). Gate G remains partial until
the app is signed with HealthKit enabled and Apple Health visibly receives data.

**Phase G update 2026-06-13 Gate-status HealthKit diagnostics:** Gate G status
now reuses the same HealthKit diagnostic path as export, replacing the static
`missing_or_unverified` phrase with runtime entitlement, availability, and
would-export counts. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T091009Z-gate-status-healthkit-diagnostics/`
built, installed, launched, and logged
`gate_status_summary ... healthkit_entitlement=0 healthkit_available=1 healthkit_hr_samples=27 healthkit_workouts=2 healthkit_hrv_samples=0`,
plus matching Gate G evidence and `healthkit_export status=missing_entitlement`.
Gate G remains partial: HR/workout payloads are locally ready, HRV stays
reference-gated, and the remaining blocker is provisioning plus Apple Health
visibility.

**Current-store status 2026-06-13 post-wake:** `docs/evidence/gate-status/20260613T085554Z-postwake-current-status/`
rebuilt, installed, launched, and confirmed the active iPhone store is rebuilding
from reset state: `sessions=0`, `sleep_days=0`, `workout_days=0`,
`hrv_validated_sessions=0`, `backup_current=1`. The run's realtime channel
connected, but the awake/moving short window was HR-only
(`realtime_rr_fraction=0.000`). Older overnight/18-session evidence remains
documented in repo evidence, but current-store gates must be rebuilt from fresh
saved sessions or a restorable Mac-side backup.

**Phase G update 2026-06-13 notification slice:** Local notification scheduling
now exists behind the cabled-device `--schedule-notifications` flag. The app
requests provisional notification authorization, waits for live BLE state, and
only schedules eligible recovery, strain-target, and low-battery notifications.
It logs every scheduled and skipped decision via `WHOOPDBG notification_*`; low
battery is skipped unless the strap battery is known and <=20%, and strain is
skipped unless the target is actually reached. This is not full Gate G complete
until the production notification cadence is wired and user-visible behavior is
verified outside the debug trigger.

**Phase G update 2026-06-13 notification delivery probe:** The app now installs a
foreground `UNUserNotificationCenterDelegate` and supports a debug-only
`--test-notification` launch argument. The diagnostic notification logs
`WHOOPDBG notification_delivered kind=diagnostic` when iOS presents it, proving
delivery without pretending a recovery, strain, or battery condition occurred.
Physical iPhone evidence in
`docs/evidence/gate-g/20260613T-gate-g-notification-delivery-smoke/` verified
provisional authorization, diagnostic scheduling, and foreground delivery. The
diagnostic flag is isolated from metric decisions unless
`--schedule-notifications` is also passed, so delivery can be verified without
triggering recovery, strain, or battery notifications.

**Phase G update 2026-06-14 Atria notification naming:** user-facing
notification copy now uses the Atria product name and generic strap language:
the diagnostic probe title is `Atria diagnostic`, the battery alert title is
`Strap battery low`, and the Bluetooth permission prompt says Atria reads live
data from the strap. Internal debug identifiers and `WHOOPDBG` logs remain
unchanged for evidence continuity. The physical iPhone run in
`docs/evidence/gate-g/20260614T140323Z-atria-notification-naming-device-verify/`
rebuilt, installed, launched, and verified the title in-device:
`notification_scheduled kind=diagnostic ... title=Atria diagnostic`, followed
by `notification_delivered kind=diagnostic ... foreground=1`; the same run kept
Gate G ready with `widget_storage=app_group_userdefaults`, `widget_app_group=1`,
`notification_delivery=debug_verified`, and `backup_current=1`. The built app
bundle was also checked locally and contains
`NSBluetoothAlwaysUsageDescription = Atria reads live data from your strap over
Bluetooth.`

**Phase G update 2026-06-14 Atria notification identifiers:** local
notification request identifiers now use `atria.*`
(`atria.recovery.ready`, `atria.strain.target`, `atria.battery.low`,
`atria.diagnostic.delivery`) while cleanup and delivery logging still handle
legacy `whoop.*` IDs. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T174820Z-atria-notification-ids-device-verify/`
built, installed, launched, connected to the strap, scheduled
`id=atria.diagnostic.delivery`, logged pending counts, and delivered it in
foreground. Gate G platform polish improved; metric exports remain gated by
validated HRV and workout evidence.

**Phase G update 2026-06-14 Atria storage paths:** new local Atria-owned files
now use Atria paths and filenames: backups write to
`Documents/atria-backups/atria-sessions-...json`, HR/RR reference packages write
to `Documents/atria-hr-reference-packages/` and
`Documents/atria-rr-reference-packages/`, active-session journals write to
`Documents/atria-active-session.json`, historical archives write to
`Documents/atria-historical/historical-archive.jsonl`, and future HRV capture
CSVs write to `Documents/atria-captures/`. Legacy `whoop-*` paths remain
readable for existing on-device backups, active journals, and historical archive
data. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T180036Z-atria-storage-paths-device-verify/`
built, installed, launched, wrote and verified an Atria backup
(`digest_match=1`), exported Atria-named HR and RR reference packages, pulled the
new backup/reference files to the Mac, and confirmed Gate H still reads the
legacy historical archive (`historical_download_validated=1`) until a future
archive write creates the new Atria path. Gate G platform polish improved; HRV
and workout exports remain source-gated.

**Phase G update 2026-06-13 notification readiness diagnostic:** Notification
scheduling now emits `WHOOPDBG notification_readiness ...` before decisions,
explicitly labeling the current path as `status=debug_trigger_only` with
`production_cadence=0`. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T091334Z-notification-readiness-diagnostic/`
built, installed, launched, logged provisional authorization, skipped Recovery
and Strain because Recovery is not high-confidence, scheduled the diagnostic
probe, and delivered it in foreground. Gate G notifications remain incomplete
until morning, strain, and battery notifications are wired to production
triggers rather than a debug launch argument.

**Phase G update 2026-06-13 production notification cadence:** Metric
notifications now run on normal app launch without `--schedule-notifications`;
the debug flag remains only for forced diagnostic delivery. Physical iPhone
evidence in
`docs/evidence/gate-g/20260613T091524Z-production-notification-cadence-smoke/`
built, installed, launched without notification flags, and logged
`notification_schedule requested=1 mode=production`, followed by
`notification_readiness status=production_cadence ... metric_decisions=1 diagnostic=0 production_cadence=1`.
No notification was scheduled because Recovery is still fallback/reference-gated
and the real strap battery was `86`, producing honest skips for Recovery,
Strain, and battery. Gate G notifications remain partial until a real
high-confidence recovery/strain or low-battery condition schedules and delivers
a production notification on device.

**Phase G update 2026-06-13 notification pending inventory:** Notification
scheduling now logs the post-decision pending-request inventory by kind, so
confidence-gated skips can be verified against the actual iOS notification
queue. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T091725Z-notification-pending-inventory/` built,
installed, launched normally, skipped Recovery and Strain because Recovery is
fallback/reference-pending, skipped battery from the real `battery_86_not_low`
strap value, and logged
`notification_pending total=0 recovery=0 strain=0 battery=0 diagnostic=0 unknown=0`.
Gate G notifications remain partial until a real eligible production condition
schedules and delivers on the physical iPhone.

**Phase G update 2026-06-13 Gate-status notification readiness:** Gate G status
now includes notification readiness alongside backup, HealthKit, and widget
state: `notifications=production_cadence_confidence_gated` and
`notification_delivery=debug_verified`. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T091912Z-gate-status-notification-readiness/`
built, installed, launched, and logged the expanded Gate G line plus matching
production notification cadence and an empty pending queue. Gate G remains
partial until a real eligible production notification delivers, HealthKit writes
to Apple Health, and a real WidgetKit/complication target is verified.

**Phase G update 2026-06-13 Gate-status widget readiness:** Gate G status now
surfaces the exact widget readiness diagnostics instead of only the coarse
`app_group_widget=diagnostic_only` label: `widget_storage`,
`widget_app_group`, `widget_target`, and `complication_target`. Physical iPhone
evidence in
`docs/evidence/gate-g/20260613T092253Z-gate-status-widget-readiness/` built,
installed, launched, and logged the expanded Gate G line with
`widget_storage=app_local_userdefaults`, `widget_app_group=0`,
`widget_target=0`, and `complication_target=0`, matching the separate
`WHOOPDBG widget_readiness` diagnostic. The same run confirmed the strap was
connected and streaming short-window RR (`realtime_rr_fraction=1.000`). Gate G
remains partial until a signed WidgetKit/app-group or Watch complication target
is added and verified on device.

**Phase G update 2026-06-13 widget snapshot groundwork:** The app now publishes a
compact app-local widget/complication snapshot with recovery percent/confidence,
strain, RHR, HRV state, and HRmax behind `--log-widget-snapshot`, logging
`WHOOPDBG widget_snapshot ...`. This is not a completed widget: `app_group=0`
until a signed WidgetKit/Watch target and shared app group are added and verified
on device.

**Phase G update 2026-06-13 widget readiness diagnostic:** Widget snapshots now
carry explicit local-only readiness metadata (`storage=app_local_userdefaults`,
`app_group=0`, `widget_target=0`, `complication_target=0`) and emit a separate
`WHOOPDBG widget_readiness status=diagnostic_only ...` line with the required
next action. Physical iPhone evidence in
`docs/evidence/gate-g/20260613T091151Z-widget-readiness-diagnostic/` built,
installed, launched, and logged both launch and delayed snapshots with the
diagnostic-only state. Gate G remains partial until a signed WidgetKit or Watch
complication target reads the snapshot through a shared app group on device.

**Phase G update 2026-06-14 widget readiness runtime scan:** Widget readiness is
no longer a hardcoded diagnostic constant. The app now scans the installed
bundle's `PlugIns/*.appex` extension points for WidgetKit/Watch targets and the
embedded provisioning profile for app-group capability strings before logging
`widget_target`, `complication_target`, and `app_group`. Physical iPhone
evidence in
`docs/evidence/gate-g/20260614T-widget-readiness-runtime-scan-device-verify/`
built, installed, launched, and confirmed the current truthful blocker state:
`widget_storage=app_local_userdefaults`, `widget_app_group=0`,
`widget_target=0`, `complication_target=0`, and Gate G `status=partial` with
blockers `healthkit_entitlement,widget_target,complication_target`. A stricter
signed-entitlement probe via `SecTaskCopyValueForEntitlement` was tried and
rejected because this iOS target did not expose the API at compile time; the
documented field remains a provisioning-profile capability check. The same run
also preserved honesty on other gates: `2A37` RR was present in the short
window, but HRV still lacks external reference validation, and workout detection
remained a near miss.

**Phase G update 2026-06-14 WidgetKit target slice:** the project now builds and
embeds a real `WhoopWidget.appex` WidgetKit extension. Physical iPhone evidence
in `docs/evidence/gate-g/20260614T-widgetkit-target-device-verify/` built,
installed, launched full-protocol, confirmed BLE notify/START/CMD_RESP, and
logged `widget_target=1` in both Gate G and `widget_snapshot`. The embedded
extension plist contains `NSExtensionPointIdentifier=com.apple.widgetkit-extension`.
Gate G remains partial, now with blockers
`healthkit_entitlement,app_group,complication_target`; the widget target blocker
is removed, while shared app-group storage and a complication target still need
signing/project work before widget data can be considered complete.

**Phase G update 2026-06-14 WidgetKit accessory complication slice:** the
`WhoopWidget` extension now supports WidgetKit accessory families for Lock
Screen / accessory complication surfaces and declares
`WhoopWidgetSupportsAccessoryFamilies=true` in its embedded plist. Physical
iPhone evidence in
`docs/evidence/gate-g/20260614T-widgetkit-accessory-complication-device-verify/`
built, installed, launched full-protocol, confirmed BLE notify/START/CMD_RESP,
and logged `widget_target=1`, `complication_target=1`, and
`widget_readiness ... action=enable_shared_app_group`. Gate G remains partial,
now with blockers `healthkit_entitlement,app_group`; the remaining widget-side
blocker is signed shared storage so the accessory surfaces can read real local
app data instead of the learning fallback.

**Phase G update 2026-06-13 current-store platform verify:** `docs/evidence/gate-g/20260613T-gate-g-current-store-platform-verify/` rebuilt, installed, and launched on the physical iPhone against the current `13` saved sessions. Backup wrote and verified `sessions=13 bytes=938780`; HealthKit correctly stayed blocked with `healthkit_export status=missing_entitlement sessions=13`; widget snapshot logged `recovery=75 confidence=learning hrv=learning strain=0.1 rhr=67 max_hr=191 app_group=0`; diagnostic and recovery notifications both delivered in foreground. The same run saw a strong short live-RR segment (`realtime_rr_fraction=0.903`, `max_rr_log_gap_s=2.0`) but this is not a Gate B pass because it was only 65 seconds and has no external RR/IBI reference.

**Phase G update 2026-06-13 post-strain platform verify:** `docs/evidence/gate-g/20260613T-gate-g-post-strain-current-store-verify/` rebuilt, installed, and launched on the physical iPhone after the Strain explainability slice. The current store now has `14` sessions; backup wrote and verified `sessions=14 bytes=987168`, HealthKit still correctly reports `missing_entitlement`, widget snapshot stays HRV-honest with `hrv=reference_pending`, and both diagnostic plus currently eligible recovery notifications delivered in foreground. The run also logged the new `strain_explain ... confidence=local` line and short-run live RR continuity of `realtime_rr_fraction=0.932`; this is platform verification only, not a HealthKit/widget Gate G exit.

**Phase G update 2026-06-13 HealthKit provisioning check:** `docs/evidence/gate-g/20260613T063536Z-gate-g-healthkit-entitlement/` tried to enable the local HealthKit entitlement and rebuild for adidshaft's physical iPhone. Xcode rejected the automatic team profile: `Provisioning profile "iOS Team Provisioning Profile: *" doesn't include the HealthKit capability` and `doesn't include the com.apple.developer.healthkit entitlement`. The experiment was reverted to keep the app buildable, then a fresh physical-device build succeeded and the existing guarded launch path correctly logged `healthkit_export status=missing_entitlement sessions=16 action=enable_healthkit_capability`. Gate G remains incomplete until the Apple developer profile/app identifier has HealthKit enabled and a rebuilt app logs `healthkit_export status=saved` with data visible in Apple Health.

**Phase G update 2026-06-13 current-store HealthKit recheck:** the HealthKit
entitlement attempt was repeated against the current post-reset store after
adding generated Info.plist Health usage strings and an explicit
`WhoopApp.entitlements` template. Enabling `CODE_SIGN_ENTITLEMENTS` still failed
before install because the wildcard team provisioning profile lacks both the
HealthKit capability and `com.apple.developer.healthkit`. The default target was
kept buildable by leaving the entitlement template unreferenced until an
explicit HealthKit-capable profile exists. Physical iPhone fallback evidence in
`docs/evidence/gate-g/20260613T100929Z-healthkit-entitlement-attempt/` built,
installed, launched, verified/pulled a backup, and logged
`healthkit_export status=missing_entitlement sessions=4 hr_samples=645
workouts=4 hrv_samples=0`. Gate G remains partial; the app can plan HR/workout
exports, but Apple Health writes are blocked by signing/provisioning.

**Phase G update 2026-06-13 current-store HealthKit signing recheck:** `docs/evidence/gate-g/20260613T133739Z-healthkit-signed-probe/` repeated the export probe against the current 14-session store. The normal signed physical-iPhone build installed and launched, BLE stayed healthy (`realtime_rr_fraction=0.984`), and the app correctly logged `healthkit_export status=missing_entitlement sessions=14 hr_samples=14921 workouts=14 hrv_samples=0`. The repo already has a `WhoopApp.entitlements` file containing `com.apple.developer.healthkit`, so a non-invasive command-line signing probe in `docs/evidence/gate-g/20260613T133936Z-healthkit-entitlement-wired/` passed `CODE_SIGN_ENTITLEMENTS=WhoopApp/WhoopApp.entitlements` and retried with `-allowProvisioningUpdates`; Xcode failed with `No Accounts: Add a new account in Accounts settings` and the current `iOS Team Provisioning Profile: *` still lacks the HealthKit capability/entitlement. The default project remains unwired to preserve physical BLE verification. Gate G cannot exit until Xcode has an Apple account/profile for `com.adidshaft.atria` with HealthKit, then the same exporter must be rebuilt, installed, authorized, and verified as `healthkit_export status=saved` plus visible Apple Health data.

**Phase G update 2026-06-14 HealthKit entitled build recheck:** a fresh
non-invasive physical-iPhone signing probe in
`docs/evidence/gate-g/20260614T044257Z-healthkit-entitled-build-recheck/` again
passed the existing entitlement file through
`CODE_SIGN_ENTITLEMENTS=WhoopApp/WhoopApp.entitlements`. The build failed before
install with the decisive provisioning errors: `iOS Team Provisioning Profile:
*` does not include the HealthKit capability and does not include the
`com.apple.developer.healthkit` entitlement. This confirms the Gate G HealthKit
blocker is external Apple signing/provisioning state, not missing exporter code.
The default target stays unwired so BLE/WHOOP physical-device verification
remains green until the app identifier/profile is updated.

**Phase G update 2026-06-14 current-store HealthKit provisioning recheck:** the
same entitlement wiring test was repeated against the 74-session current store
in `docs/evidence/gate-g/20260614T053244Z-healthkit-provisioning-blocker/`.
Temporarily wiring `CODE_SIGN_ENTITLEMENTS = WhoopApp/WhoopApp.entitlements`
failed physical-iPhone build with Xcode exit 65: the current `iOS Team
Provisioning Profile: *` still lacks the HealthKit capability and
`com.apple.developer.healthkit` entitlement. The target wiring was removed
again, then a green cabled fallback launch with
`--whoop-healthkit-export --whoop-log-gate-status` logged
`healthkit_export status=missing_entitlement sessions=74 hr_samples=38816
workouts=74 hrv_samples=0 action=enable_healthkit_capability` and Gate G
`healthkit_entitlement=missing`. This confirms the app has local HR/workout data
ready, but Gate G HealthKit remains blocked until the Apple profile/app ID is
HealthKit-capable; no HRV samples are eligible because Gate B reference
validation is still missing.

**Phase G update 2026-06-13 notification confidence guard:** Recovery-ready and strain-target notifications now require high-confidence Recovery, so fallback/RHR-only Recovery no longer produces user nudges. Physical iPhone evidence in `docs/evidence/gate-g/20260613T-gate-g-notification-confidence-guard/` logged `notification_skip kind=recovery reason=recovery_confidence_fallback_not_high` and `notification_skip kind=strain reason=recovery_confidence_fallback_not_high`, while the diagnostic delivery probe still scheduled and delivered. Gate G remains open for production cadence, HealthKit entitlement-backed writes, and real widget/complication surfaces.

**Phase G update 2026-06-13 battery notification evidence:** Battery reads now
emit an explicit `WHOOPDBG battery level=... source=2A19` line, so the
low-battery notification decision can be traced to the physical strap value.
Physical iPhone evidence in
`docs/evidence/gate-g/20260613T090003Z-battery-read-notification-evidence/`
built, installed, launched, read `battery level=87`, skipped the low-battery
notification with `notification_skip kind=battery reason=battery_87_not_low`,
kept recovery/strain notifications confidence-gated, and delivered the
diagnostic foreground notification. This strengthens Gate G notification
evidence; Gate G remains incomplete until production notification cadence,
HealthKit, and widget/app-group surfaces are verified.

**Phase H — Protocol expansion.** Probe opcodes for SpO2/skin-temp/historical download; decode IMU/PPG; pull stored history off the strap.

**Phase H update 2026-06-13 protocol packet logger:** the app now logs all valid non-realtime/non-history WHOOP packet families as `WHOOPDBG protocol_packet ...` instead of silently dropping them, and has a conservative `WHOOPDBG imu_candidate validated=0 ...` path for packet `0x33` if it appears. Physical iPhone evidence in `docs/evidence/gate-h/20260613T064008Z-gate-h-protocol-packet-logger/` built, installed, and launched a `1400,6000,1600` sweep. The run captured `0x28:117`, `0x2f:1552`, `0x30:32`, `0x31:65`, and `0x32:131` on `61080005`, with `historical_2f_frames=1552` and no `0x33` IMU frames. `0x14` and `0x60` again produced short clean live-RR segments (`100.0%` RR-bearing each), while `0x16` pulled old historical data with no live/history overlap (`separation_seconds=6549187.0`). Gate H remains incomplete: historical download is reproducible but not decoded/validated enough for metrics, and no new sensor has been decoded.

**Phase H update 2026-06-13 diagnostic text logger:** packet `0x32` now has a dedicated `WHOOPDBG diagnostic_text validated=0 ...` logger that extracts printable UTF-8 runs while preserving the raw payload and full frame. Physical iPhone evidence in `docs/evidence/gate-h/20260613T064457Z-gate-h-diagnostic-text-logger/` built, installed, and launched the same `1400,6000,1600` sweep. The run captured `0x28:87`, `0x2f:1030`, `0x30:44`, `0x31:47`, and `0x32:212` on `61080005`, with `historical_2f_frames=1030`, `realtime_rr_fraction=1.000`, and no `0x33` IMU frames. Diagnostic examples include `SLEEPFLAG: moving from state 'STILL' to 'WAKE'`, `motion_short = 0.446667`, `SUPERVISOR: SOC report`, charger events, and BPK/NFC events. These logs are protocol clues, not validated sensor metrics; historical data again did not overlap live time (`separation_seconds=6548559.0`), so Gate H remains incomplete.

**Phase H/Gate E update 2026-06-13 sleep-motion hint classifier:** packet
`0x32` diagnostic text now has a conservative `WHOOPDBG sleep_motion_hint
validated=0 ...` classifier for obvious sleep/motion phrases such as
`SLEEPFLAG`, `motion_short`, and `deepsleep`. Physical iPhone evidence in
`docs/evidence/gate-h/20260613T092549Z-sleep-motion-hint-diagnostic/` built,
installed, launched, and ran `1400,6000,1600` with trim ACKs. The run captured
`0x28:76`, `0x2f:544`, `0x30:12`, `0x31:27`, and `0x32:214`, with
`realtime_rr_fraction=1.000`; the new logger emitted 7
`sleep_motion_hint validated=0 source=0x32 kind=deepsleep` rows. This run did
not contain `motion_short` or `SLEEPFLAG`, so no low-motion claim is made and
sleep remains HR-only/low-confidence. The classifier is observe-only until a
validated motion/IMU decode exists.

**Phase H/Gate E update 2026-06-13 sleep-motion summary counters:**
`live_device_debug.sh` summaries now include `sleep_motion_hint_count` and
`sleep_motion_hint_kinds` globally and per probe segment. Replay verification of
the previous physical diagnostic log reported `sleep_motion_hint_count=7`,
`sleep_motion_hint_kinds=deepsleep:7`, and
`segment_3_sleep_motion_hint_count=7`. Physical iPhone smoke evidence in
`docs/evidence/gate-h/20260613T092943Z-sleep-motion-summary-smoke/` built,
installed, launched, and emitted the new zero-count summary fields on a normal
short realtime run (`realtime_rr_fraction=1.000`). This improves evidence
quality only; it does not validate `0x32` as motion or upgrade sleep confidence.

**Phase H/Gate E update 2026-06-13 local motion observe status:** the in-app
`Local status` card and `WHOOPDBG local_status` log now surface the diagnostic
sleep/motion hint source and aggregate hint counts while keeping
`motion_validated=0`. Physical iPhone evidence in
`docs/evidence/gate-h/20260613T093517Z-local-motion-observe-status-aggregate/`
built, installed, launched, and ran the `1400,6000,1600` sweep after the strap
had been worn overnight. The first status line reported
`motion_source=unavailable motion_hint_count=0 motion_hint_kinds=none`; after
`0x32` diagnostic text arrived, local status advanced through
`motion_source=diagnostic_observe_only motion_hint_count=12
motion_hint_kinds=deepsleep:12 external_rr_reference=missing`. The same run
reported `realtime_rr_fraction=0.974`, `hrv_max_rr_gap_s=2.0`,
`historical_2f_frames=726`, and `sleep_motion_hint_count=12`. This is a
visibility and evidence improvement only: `0x32` text is not decoded motion,
sleep remains learning/low-confidence, and HRV remains reference-pending.

**Phase H/Gate E update 2026-06-13 sleep-motion diagnostic persistence:**
saved sessions and local backups now preserve observe-only motion evidence from
`0x32` diagnostic text as `motionHintCount`, `motionHintKinds`,
`motionEvidenceSource`, and `motionEvidenceValidated=false`. Physical iPhone
evidence in
`docs/evidence/gate-e/20260613T125404Z-sleep-motion-diagnostic-persistence/`
built, installed, launched, and ran `1400,6000,1600` with trim ACKs. The run
captured `sleep_motion_hint_count=3` (`motion_short:1,sleepflag:2`), auto-saved
a session with `motion_hints=2 motion_source=diagnostic_observe_only
motion_validated=0`, and pulled a backup JSON containing the same observe-only
fields. This improves durability and auditability only: `0x32` text is not
validated IMU, sleep remains low-confidence, Gate E still needs a real workout,
and HRV remains reference-pending.

**Phase H/Gate E update 2026-06-13 motion-short audit fields:** saved sessions,
sleep-validation logs, aggregate sleep candidates, and local backups now carry
observe-only numeric `motion_short` audit fields when packet `0x32` diagnostic
text includes them: `motion_short_count`, mean/min/max, count over `1.0`, and
`motion_short_validated=0`. Physical iPhone evidence in
`docs/evidence/gate-h/20260613T142052Z-motion-short-audit-device-verify/`
built, installed, launched, ran `1400,6000,1600`, and saw `0x32` visibility
without a numeric `motion_short` value, so the app persisted
`motion_short_count=0` and kept sleep confidence low. Follow-up evidence in
`docs/evidence/gate-h/20260613T142335Z-motion-short-backup-totals-device-verify/`
verified backup accounting with `motion_short_samples=0`,
`current_motion_short_samples=0`, and `digest_match=1`. This is honest
persistence/accounting only; it does not validate IMU or upgrade sleep.

**Phase H update 2026-06-13 data-range field logger:** command-response logging now has a dedicated read-only `WHOOPDBG data_range_response validated=0 ...` path for `0x22` responses, including overlapping u32/u16 fields, Unix-looking candidates, `last_realtime_unix`, and the raw status. Physical iPhone evidence in `docs/evidence/gate-h/20260613T-gate-h-data-range-field-logger/` first preserved a failed local build (`Data` vs `[UInt8]`), then built, installed, launched, and ran `1400,6000,2200,1600` with trim ACKs. The `0x22 [00]` response had `status_len=69 lead=090101 body_len=66`; candidate fields included old-history timestamps `1774784553`/`1774784591` (`2026-03-29T11:42:33Z`/`11:43:11Z`) and a live-ish candidate `1781334714` (`2026-06-13T07:11:54Z`) near `last_realtime_unix=1781334723`. The following `0x16 [00]` still pulled old history (`historical_2f_frames=1225`, `historical_unix_first=1774784553`, `historical_unix_last=1774785693`, `separation_seconds=6548971`), so Gate H remains incomplete. Next selector work should derive a non-blind read-pointer/range experiment from this `0x22` evidence; do not claim historical HRV or stored-session decode yet.

**Phase H update 2026-06-13 whoof-layout historical analysis:** `tools/analyze_historical_2f.py` now has an explicit `--whoof-layout` mode for the `madhursatija/whoof`-derived hypothesis: historical HR at payload offset `17`, RR count at `18`, and RR values from offset `19`. The analyzer was run against the three physical-iPhone current-Unix selector captures and saved in `docs/evidence/gate-h/20260613T-gate-h-whoof-layout-analysis/`; it now validates the full logged frames through `whoop_codec.py` before analyzing payloads. All three captures were codec-clean (`codec_bad_frames=0`), so the transport/frame decode is validated, but the RR interpretation is still not metric-ready: current-Unix had `2399` `0x2f` frames, `1148` RR values, `hr_mae_bpm=4.72`, but `ready_windows=0`, `max_gap_s=39.621`, `live_history_overlap=0`, and `gate_b_ready=0`; prefix0/prefix1 also had `ready_windows=0` with no live/history overlap. This exhausts the bare/prefix0/prefix1 current-Unix selector family for now. Historical download is reproducible and one RR-layout hypothesis is plausible, but it still must not feed HRV/Recovery/Trends/HealthKit until the stored range overlaps the intended session and is validated against an external RR/IBI reference.

Read-only `whoof` cross-check for Gates C-H: useful scaffolding exists for
Recovery, Strain, Sleep, workout detection, Trends, and protocol framing, but it
is not validated enough to satisfy our gates. It uses heuristic recovery/sleep
logic, has HealthKit import rather than native HealthKit write, lacks
widgets/complications, and documents several speculative sensor decodes. Reuse
ideas only behind our device evidence and confidence gates.

**Cross-gate audit 2026-06-13:** the app and cabled-device launcher now support
`--log-gate-status` / `--whoop-log-gate-status`, a single on-device
`WHOOPDBG gate_status ...` diagnostic that summarizes the current local store
without upgrading any metric past its evidence. Physical iPhone evidence in
`docs/evidence/gate-status/20260613T-gate-status-diagnostic/` built,
installed, launched, wrote a fresh backup, verified its deterministic digest, and
then logged `sessions=18 days=2 rest_hr=73 max_hr=191 hrv_validated_sessions=0
hrv_baseline_samples=0 backup_available=1 backup_current=1`. Gate B is
`reference_pending`, Gate C is `learning` (`0/7` validated HRV baseline), Gate D
is `partial` until external HR/rest-to-max validation, Gate E is `partial`
(`sleep_days=1`, `workout_days=0`, motion unavailable), Gate F is `learning`
(`90d` coverage `2%`, HRV reference-gated), Gate G is `partial`
(`backup_current=1` but HealthKit/widget incomplete), and Gate H is `partial`
(historical analysis external, no metric-ready stored RR or new sensor). The
first smoke exposed a stale latest-backup mismatch; the final implementation now
computes `backup_current` by comparing backup and current-store content digests,
so the audit catches that class of false-positive platform evidence.

**Phase B update 2026-06-13 RR-quality surface:** the app now exposes a short
rolling RR continuity/contact state in the HRV card, capture readiness panel, and
`WHOOPDBG rr_quality` logs. Physical iPhone evidence in
`docs/evidence/gate-b/20260613T083750Z-rr-quality-surface-smoke/` built,
installed, launched, wrote/verified/pulled a backup, and logged a clean short
window: `state=ready fraction=1.000 rr_frames=48 total_frames=48
max_rr_gap_s=1.3 window_s=45`. This improves the honesty/debuggability of the
`learning` state, but it is not a Gate B pass: the smoke lasted 55 seconds,
`hrv_ready=False`, and no external RR/IBI reference comparison was made.

**Phase B/H update 2026-06-13 historical fallback after live collapse:** after a
still 5-minute attempt failed, a fresh physical-iPhone historical fallback run in
`docs/evidence/gate-b/20260613T111749Z-historical-fallback-fresh-current/`
built, installed, launched, and ran a bounded `0x16` recent-history sweep with
trim ACKs. The strap emitted `836` codec-valid `0x2f` frames and the `whoof`
layout remained plausible (`frames_with_rr=250`, `rr_values=327`,
`hr_mae_bpm=6.61`, `hr_within_10_bpm_percent=79`), but it was not metric-ready:
`ready_windows=0`, best historical window `max_rr_gap_s=87.479`, and
`live_history_overlap=0` with `live_history_separation_seconds=6556516.3`. The
same broad sweep damaged live continuity (`realtime_rr_fraction=0.306`,
`max_rr_log_gap_s=64.6`). Conclusion: local chunking can preserve HR/session
evidence but cannot recover RR absent from `rrnum=0` live frames. The correct
fallback is the strap's own stored-session transfer, isolated from live HRV
capture and still forced to `learning` until the historical range overlaps the
intended session and passes external RR/IBI reference validation.

**Phase B/H update 2026-06-14 historical live-RR cross-check tool:** the
historical analyzer now has `--live-rr-reference`, which reconstructs candidate
historical RR in strap time and compares it only against overlapping live `0x28`
RR windows. It emits `layout_live_validated=0` and `gate_b_ready=0` when there is
no overlap, and still warns that same-strap live RR is not an external
reference. This prevents old stored-history blocks from being treated as
validation for the current session. HRV remains `learning` unless a historical
layout overlaps live RR for shape validation and later matches an external
RR/IBI reference within `+/-5 ms`.

**Phase E update 2026-06-13 real gym return pull + gap-aware workout detector:**
after adidshaft's real gym workout, the app process was still alive on the cabled
iPhone and the on-device `Documents/sessions.json` was pulled without
relaunching. Evidence in
`docs/evidence/gate-e/20260613T-workout-return-device-pull/` shows
`sessions=20`, `ready=0`, and the latest workout-period row (`Auto-saved`,
20:57:06-21:17:08 IST) had `duration_s=1202` but only `observed_s=130` after
dropping HR sample gaps over `5s`, with `dropped_gap_s=1072`,
`max_gap_s=1011.7`, `gap_count=10`, `avg=94`, `peak=107`, and threshold `133`.
The workout did not pass: the saved wrist-HR stream never reached sustained
elevated HR, and Bluetooth/no-data gaps made the observed coverage too short.
The detector now treats gaps over `5s` as missing data, resets sustained bouts
across them, bases readiness on observed stream duration, and logs
`observed_duration_s`, `dropped_gap_s`, `max_gap_s`, and `gap_count` for live
auto-save, saved-session replay, and per-session diagnostics. Physical iPhone
verification in
`docs/evidence/gate-e/20260613T-workout-gap-aware-device-verify/` logged
`workout_validation status=learning
reason=observed_duration_below_10m_stream_gaps ... workouts_matching=0`, so the
new blocker naming is confirmed on device. The AirPods music interruption is
documented as a possible BLE/2.4 GHz coexistence clue, but not proven because
attached-device unified-log collection required root.

**Phase E update 2026-06-13 aggregate workout chunks:** the app now evaluates
same-day saved-session workout chunks as conservative aggregates, answering the
"store locally and transmit/use later" fallback without weakening the workout
bar. Chunks are clustered only when the saved-session gap is `<=30m`, and the
same detector still treats HR sample gaps over `5s` as missing data that reset
sustained elevated-HR bouts. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T-aggregate-workout-chunks-device-verify-3/`
built, installed, launched, and logged
`workout_replay_summary ... best_source=aggregate_chunks best_chunks=5
best_span_s=3425 ... peak_hr=114 threshold_hr=133 elevated_s=0`. The delayed
workout verifier selected the same aggregate (`Auto-saved + 3 chunks`) and
correctly stayed `learning`:
`workout_validation status=learning reason=elevated_seconds_below_required
source=aggregate_chunks chunks=5 observed_duration_s=1009 dropped_gap_s=2416
max_gap_s=1011.7 elevated_s=0 required_elevated_s=353 workouts_matching=0`.
This confirms local chunk aggregation works, but the real gym recording still
does not pass Gate E because the received wrist-HR samples never reached the
personalized elevated-HR threshold. No workout was fabricated.

**Phase E update 2026-06-13 workout capture-integrity labels:** workout
readiness now emits `primary_blocker` and `stream_coverage_percent` everywhere
the detector is surfaced: live workout diagnostics, `local_status`, aggregate
workout candidates, saved replay, delayed validation, and Gate E status. The
physical iPhone run in
`docs/evidence/gate-e/20260613T-workout-capture-integrity-device-verify-2/`
built, installed, launched, and verified the distinction. The real gym
aggregate still stayed `learning` with
`primary_blocker=stream_gaps_and_hr_below_threshold`,
`stream_coverage_percent=29`, `observed_duration_s=1009`,
`dropped_gap_s=2416`, `peak_hr=114`, `threshold_hr=133`, and `elevated_s=0`.
The simultaneous short live smoke correctly reported the different blocker
`duration_below_10m_and_hr_below_threshold` with `stream_coverage_percent=100`.
This does not pass Gate E; it makes the next workout attempt debuggable without
inventing missing HR evidence.

**Phase D/E update 2026-06-13 HR artifact confirmation:** after the real gym
capture showed stream gaps plus HR below the personalized workout threshold, the
HR artifact filter was corrected to match the documented hold/confirm policy.
An isolated `>50 bpm` jump from the recent median is held and logged as
`hr_artifact`; a second aligned sample within 10s confirms the new level and
both real samples are accepted; the first large jump after a `>5s` accepted-HR
gap is accepted as `stale_median_after_gap` so a BLE/contact interruption cannot
pin workout HR to a stale resting median. Physical iPhone evidence in
`docs/evidence/gate-d/20260613T-hr-artifact-confirmation-device-verify/` built,
installed, launched, and logged the policy self-test:
`unconfirmed_jump`, `confirmed_jump`, and `stale_median_after_gap`. The same run
kept Gate E honest (`workout_days=0`, `workout_state=learning`) and did not
invent elevated HR. Gate D/E still need a fresh real effort to prove the fixed
filter captures sustained elevated HR correctly.

**Phase E update 2026-06-13 quiet long-wear logging:** after the gym return
included a user report of AirPods music interruption, the app reduced avoidable
normal-run logging load without changing BLE subscriptions or local collection.
Raw packet hex logs (`standardHR payload`, `realtimeFrame`, raw `frame ch=...`,
unknown packet hex, and raw RR packet dumps) are now gated behind
`--whoop-log-ble-frames`; the debug harness still enables them by default for
forensic evidence and adds `--quiet-ble-logs` for long wear. This does not prove
the app caused the AirPods interruption, but it removes a plausible avoidable
source of CPU/unified-log pressure while preserving checkpoints and high-level
diagnostics. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T-quiet-ble-logging-device-verify/` built,
installed, launched with `--quiet-ble-logs`, and showed live workout samples
advancing (`samples=29`, `stream_coverage_percent=100`) plus
`session_checkpoint status=saved`; raw frame counters were intentionally empty.
Gate E remains open until a real elevated-HR workout validates.

**Phase E update 2026-06-13 BLE link diagnostics:** the app now persists and
surfaces BLE link attempts, disconnects, successes, failures, last
status/reason/error, and disconnect auto-save outcome in `local_status` and Gate
E status. `didFailToConnect` now falls back to a fresh scan so a stale peripheral
does not strand collection, and `live_device_debug.sh --reset-link-diagnostics`
can clear counters before a physical-device experiment. Physical iPhone evidence
in `docs/evidence/gate-e/20260613T-ble-link-diagnostics-device-verify-2/`
built, installed, launched with quiet BLE logs, reset the counters, and observed
iOS restoring the WHOOP link:
`ble_link status=connected reason=state_restore_connected successes=1
attempts=0 disconnects=0 failures=0`. Later `local_status` carried
`ble_link_successes=1`, `ble_link_disconnects=0`, `ble_link_failures=0`, while
the checkpoint path honestly reported `skipped_insufficient_samples` because
the short run had only `8` samples at the checkpoint tick. The same run still
logged live workout sample gaps (`stream_coverage_percent=50`,
`max_gap_s=10.5`,
`primary_blocker=stream_gaps_and_hr_below_threshold`) without any BLE disconnect
counter increase, so this phase improves attribution rather than passing Gate E.
Gate E remains open until a real elevated-HR workout is captured and detected.

**Phase E update 2026-06-13 HR sample-gap attribution:** the app now persists
raw `2A37` notification count, accepted HR sample count, zero-contact samples,
artifact holds/drops, raw notification gaps, accepted-sample gaps, and max
raw/accepted gap seconds. The same evidence appears in `local_status` and Gate E
status as `hr_*` fields, and `live_device_debug.sh --reset-sample-diagnostics`
clears the counters before a physical-device run. Physical iPhone evidence in
`docs/evidence/gate-e/20260613T-sample-gap-attribution-device-verify/` built,
installed, launched with quiet logs, reset both link and sample ledgers, and ran
for 60 seconds. The final local status showed `hr_raw_2a37=64`,
`hr_accepted=64`, `hr_zero=0`, `hr_artifact_held=0`,
`hr_artifact_dropped=0`, `hr_raw_gaps=0`, `hr_accepted_gaps=0`,
`hr_max_raw_gap_s=0.0`, and `hr_max_accepted_gap_s=0.0`; live workout tick 10
reported `stream_coverage_percent=100`, `samples=62`, `observed_duration_s=52`,
and `max_gap_s=0.0`. This proves the app-side path did not drop samples during
the controlled verifier, but it does not pass Gate E because it was not a real
elevated-HR workout. The next real workout attempt should use the `hr_*` fields
to distinguish upstream notification/contact/range/coexistence loss from
app-side filtering or genuinely below-threshold HR.

**Phase E update 2026-06-13 session HR-quality persistence:** saved sessions and
local backups now carry audit-only HR sample-quality fields (`hrRaw2A37`,
`hrAccepted`, `hrZero`, `hrArtifactHeld`, `hrArtifactDropped`, `hrRawGaps`,
`hrAcceptedGaps`, `hrMaxRawGap`, `hrMaxAcceptedGap`). Physical iPhone evidence
in `docs/evidence/gate-e/20260613T-session-hr-quality-persistence-device-verify/`
saved a checkpoint with `hr_raw_2a37=65`, `hr_accepted=65`, no zero-contact
samples, no artifact filtering, and no raw/accepted gaps; the automatic backup
carried matching HR-quality totals. The first verify-only relaunch exposed an
existing digest mismatch even though the HR totals matched, caused by baseline
rebuild timestamps rather than the new fields. Baseline learning/rebuild now
uses the source session end time, and the final physical verify logged
`session_backup_verify status=ok ... hr_raw_2a37=289 current_hr_raw_2a37=289
hr_accepted=289 current_hr_accepted=289 hr_raw_gaps=1 current_hr_raw_gaps=1
hr_accepted_gaps=1 current_hr_accepted_gaps=1 ... digest_match=1`. This makes
future unattended workout captures posthoc-auditable; it still does not pass
Gate E without a detected elevated-HR workout.

**Phase E update 2026-06-14 workout threshold-gap diagnostics:** workout
readiness now reports `threshold_gap_bpm` everywhere the detector is surfaced:
live workout diagnostics, workout auto-save, per-session replay, aggregate
workout candidates, delayed validation, and saved-session Mac audits. This keeps
the detector strict while making below-threshold failures concrete. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-threshold-gap-device-verify/` pulled the current
store (`43` sessions), rebuilt, installed, launched, and verified the new field
on device. The best aggregate workout candidate stayed `learning`:
`chunks=3`, `observed_duration_s=647`, `dropped_gap_s=368`,
`stream_coverage_percent=64`, `peak_hr=120`, `threshold_hr=133`,
`threshold_gap_bpm=13`, `elevated_s=0`, and
`primary_blocker=stream_gaps_and_hr_below_threshold`. Delayed validation of
`Unattended workout checkpoint` selected the same aggregate and also logged
`threshold_gap_bpm=13`. Gate E remains partial (`workout_days=0`); no workout
was fabricated from below-threshold wrist-HR data.

**Phase D/E update 2026-06-14 HR-reserve workout threshold fix:** the sustained
workout detector no longer uses `70%` of absolute HRmax as its elevated-HR
threshold. It now uses the plan-aligned personalized HR-reserve threshold
`rest + 0.50 * (HRmax - rest)`, shared by saved-session replay, live workout
status, workout auto-save, preflight diagnostics, and the Mac store analyzer.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-hrr-workout-threshold-device-verify/` built,
installed, launched, and logged `workout_preflight ... threshold_hr=121
hrr50_hr=121 threshold_method=hrr50` for `rest_hr=52` and `max_hr=190`. The
same run replayed the gym-labelled saved chunks and still refused to fabricate a
workout: best aggregate `peak_hr=120`, `threshold_hr=121`,
`threshold_gap_bpm=1`, `elevated_s=0`, `observed_duration_s=692`,
`dropped_gap_s=1652`, and `workout_validation status=learning`. This rules out
the previous recording as a missed workout caused only by an over-high absolute
HRmax threshold; Gate E remains partial until a real sustained elevated-HR
workout is captured and validates on device.

**Phase E update 2026-06-14 live capture diagnosis:** live workout diagnostics
and strict workout auto-save rows now include `capture_diagnosis`,
`capture_action`, and the HR sample-quality ledger for the current session.
The diagnostic labels are fail-closed: contact loss, stream gaps, artifact
filtering/motion suspicion, below-threshold received HR, too-short collection,
or valid candidate. They do not change readiness. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-live-workout-capture-diagnosis-device-verify-2/`
built/installed the app, relaunched low-radio Long Wear, and reduced the
patched log to `live_ticks=6`, `capture_diagnosis=stream_gaps`,
`capture_action=keep_learning_reconnect_or_keep_phone_near`,
`stream_coverage_percent=70`, `duration_s=1348`, `observed_duration_s=937`,
`dropped_gap_s=411`, `max_gap_s=134.3`, `hr_raw_2a37=1090`,
`hr_accepted=1090`, `hr_zero=0`, `hr_artifact_held=0`,
`hr_artifact_dropped=0`, and `peak_hr=87` against `threshold_hr=122`.
The same transcript saw real standard `2A37` RR (`standard_2a37_rr_values=116`)
and kept `gate_e_workout_ready=0`. This does not pass Gate E; it makes the
next real workout failure actionable without threshold churn.

**Phase E update 2026-06-14 one-command workout capture preset:** the launcher
now has a canonical `--gate-e-workout-capture` preset so the next real workout
attempt cannot accidentally omit required evidence. The preset defaults to label
`gate-e-hrr50-workout`, `1200s` capture, quiet BLE logs, reset link/sample
diagnostics, HRR50 preflight, `60s` checkpoints, `15s` live-workout diagnostics,
`15s` strict auto-save checks, delayed validation at `900s`, daily rollups,
Gate status, backup write, and backup verify. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-workout-capture-preset-device-verify/`
used a short override (`--seconds 75 --verify-workout-after 20`) and verified
the preset expansion on device: `workout_preflight ... threshold_method=hrr50`,
`session_checkpoint schedule interval_s=60.0 label=gate-e-hrr50-workout`,
`live_workout schedule interval_s=15.0`, `workout_auto_save schedule
interval_s=15.0`, `session_backup_verify status=ok ... digest_match=1`,
`session_checkpoint status=saved ... mode=upsert`, and
`workout_validation status=learning reason=no_saved_session` for the short rest
smoke. This is execution hardening, not a Gate E pass; the next real attempt
should run `./live_device_debug.sh --gate-e-workout-capture`.

**Phase E update 2026-06-14 current-store aggregate audit:** after the user
returned and the app had remained open with the strap on, the current on-device
store was pulled and rechecked in
`docs/evidence/gate-e/20260614T-current-store-aggregate-audit/`. The Mac store
analyzer now mirrors the app's aggregate chunk behavior (`>=60s` chunks,
same-day clusters, `30m` cluster gap, HRR50 threshold, `5s` sample-gap bout
reset) instead of only listing individual sessions. The physical iPhone run
built, installed, launched, and logged the same app-side verdict:
`aggregate_workout_summary candidates=6 ready=0`, best source
`aggregate_chunks`, `chunks=9`, `duration_s=6814`, `observed_duration_s=1738`,
`dropped_gap_s=5076`, `peak_hr=120`, `threshold_hr=121`, `elevated_s=0`,
`required_elevated_s=608`, `longest_bout_s=0`, `workout_validation
status=learning`, and `gate_status gate=E status=partial`. A threshold
sensitivity check showed this is not a one-bpm edge: even at `115 bpm`, the best
aggregate has only `17s` elevated and a `9s` longest bout. This rules out
missing local chunk aggregation and a simple threshold bug for this workout
capture. The recorded wrist-HR evidence is insufficient for a sustained
elevated-HR workout, so no workout is fabricated and Gate E remains partial
(`sleep_days=1`, `workout_days=0`).

**Gate E update 2026-06-14 threshold sensitivity:** the app and
`tools/analyze_workout_store.py` now run a diagnostic-only saved-workout replay
at HRR35/40/45/50 without changing the production HRR50 detector. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-workout-threshold-sensitivity-device-verify/`
built, installed, launched, pulled `sessions.json`, and logged
`WHOOPDBG workout_threshold_sensitivity ... diagnostic_only=1
detector_threshold_hrr50_unchanged=1`. The sensitivity summary was
`ready_fractions=none`: HRR35 chose the gym `Auto-saved + 3 chunks` aggregate
but still had only `92s` elevated against `353s` required and a `44s` longest
bout; HRR45/50 chose the broader `Unattended workout checkpoint + 2 chunks`
aggregate but still had only `18s/0s` elevated against `838s` required, with
`stream_coverage_percent=22`. Gate E remains partial with
`workout_days=0`, `workout_saved_ready=0`, and `workout_near_miss=1`, but this
rules out a simple threshold bug or one-bpm edge as the reason the saved workout
did not auto-detect.

**Gate E update 2026-06-14 saved workout status surface:** the in-app Local
Status panel and `WHOOPDBG local_status` now surface the best saved workout
attempt from the same replay used by Gate E status. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-saved-workout-status-device-verify/` built,
installed, launched, pulled `sessions.json`, and logged
`workout_state=near miss`, `saved_workout_source=aggregate_chunks`,
`saved_workout_chunks=14`, `saved_workout_near_miss=1`,
`saved_workout_ready=0`, and `workout_days=0`. The saved attempt blocker is
now explicit in normal status: `stream_coverage_percent=22`,
`duration_s=10796`, `observed_s=2395`, `dropped_gap_s=8401`, `peak_hr=120`,
`threshold_hr=121`, `threshold_gap_bpm=1`, `elevated_s=0`, and
`required_elevated_s=838`. This does not pass Gate E; it removes the hidden
analysis step after a long workout carry and shows that the current saved
evidence still lacks sustained elevated-HR coverage.

**Gate E update 2026-06-14 HR-only workout capture path:** the app and
launcher now have a labeled standard-HR-only workout mode:
`live_device_debug.sh --gate-e-hr-only-workout-capture` passes
`--whoop-standard-hr-only`, subscribes to standard `2A37` HR/RR plus battery,
skips WHOOP custom notify streams, skips realtime START, disables history ACKs,
and logs `standardHR` packets even with quiet BLE logs. Physical iPhone
evidence in
`docs/evidence/gate-e/20260614T-hr-only-workout-capture-smoke-device-verify/`
built, installed, launched, and pulled `sessions.json`. The smoke recorded
`standard_2a37_frames=41`, `standard_2a37_rr_values=17`,
`last_rr_quality_source=2a37`, `realtime_frames=0`, and
`frame_61080003/04/05/07_count=0`; live workout diagnostics showed
`stream_coverage_percent=100`, `dropped_gap_s=0`, and `max_gap_s=0.0` while
remaining `learning` because this was a short/resting capture
(`duration_below_10m`, `peak_hr=87`, `threshold_hr=121`). This does not pass
Gate E, but it creates the next high-signal real-workout route: isolate workout
HR coverage and possible AirPods/Bluetooth coexistence from proprietary WHOOP
traffic instead of re-running the same full protocol path.

**Gate execution update 2026-06-14 current blocker reducer:** added
`tools/analyze_gate_status.py`, which parses real `WHOOPDBG gate_status` logs
into a compact blocker/next-action table for gates A-H. Physical iPhone
evidence in `docs/evidence/gate-status/20260614T-current-blocker-audit/` built,
installed, launched, pulled the current store, and reduced the fresh
`--log-gate-status` run to: Gate B `external_rr_reference`, Gate C
`validated_hrv_baseline_0/7`, Gate D `external_hr_rest_to_max_validation`, Gate
E `stream gaps and hr below threshold`, Gate F `coverage_2pct_hrv_gated_1`,
Gate G `healthkit_entitlement,widget_target,complication_target`, and Gate H
`historical_rr_metric_ready,new_sensor_validated`. This does not pass a gate; it
is a decision-speed tool so future execution starts from current physical-device
evidence instead of retrying ruled-out START, ACK, threshold, or aggregation
paths.

**Gate B/G coexistence update 2026-06-13 single START default:** standard BLE
`2A37` is now the primary HR/RR source, so repeated realtime START sends are no
longer a default recovery policy. The app sends the validated `0x03 0x01` START
once after `61080005` notify confirmation; `--whoop-realtime-start-retries N`
remains available only as a labeled protocol experiment, and retry loops stop as
soon as standard HR/RR or proprietary realtime frames prove the stream is alive.
Physical iPhone evidence in
`docs/evidence/gate-b/20260613T-single-start-default-device-verify/` built,
installed, launched, and confirmed exactly one START send plus one command
response (`cmd_response_count=1`), no retry/restart spam
(`realtime_restarts=0`, `realtime_reasserts=0`, no `realtimeRetry` rows), and
healthy short live RR (`standard_2a37_rr_values=33`,
`realtime_rr_fraction=0.931`). This reduces needless BLE command chatter during
long recordings and the reported AirPods interruption investigation, without
relaxing HRV gates: the 30-second smoke still ended `hrv_ready=False`.

**Phase B update 2026-06-14 saved RR reference package:** after pulling the
current app container `sessions.json` from adidshaft's cabled iPhone
(`43` sessions, `4564` saved RR samples, `21307` HR points), the app now exports
the best saved strict 5-minute RR window for external comparison via
`--whoop-export-rr-reference-package`. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T-rr-reference-package-drop-only-device-verify/`
built, installed, launched, logged `rr_reference_package status=ok`, and pulled
both CSV and manifest from `Documents/whoop-rr-reference-packages/`. The selected
real RR window was `raw=347`, `kept=317`, `conf=91`, `max_rr_gap_s=2.8`,
`interpolated=0`, `rmssd=50.2`, `sdnn=54.1`, `pnn50=28.2`, and `lnrmssd=3.92`.
The analyzer was corrected to honor the Gate B contract: RR artifacts are
dropped, not interpolated/backfilled, and the self-parse validator smoke matched
the exported CSV (`rmssd_delta_ms=0.0`) only as a parser check. Gate B remains
`reference_pending` because no external RR/IBI recording has been compared
within `+/-5 ms` RMSSD.

**Phase B update 2026-06-14 bounded RR export:** a later current-store export
run found the launch-time bottleneck: the exhaustive saved-RR package scan could
get the cabled iPhone process killed before HealthKit/reference export evidence
finished. A bounded 15-second-step RR window scanner now preserves the same
Gate B artifact rules (`300-2000 ms`, drop `|delta RR| > 20%`, confidence =
kept/raw, no `>3 s` gap, `>=240` kept) without invoking the full live HRV
analyzer for every beat. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T124249Z-bounded-rr-export-healthkit-device-verify/`
built, installed, launched, logged `launch_exports status=completed`, and
pulled a real RR package: `raw=368`, `kept=361`, `conf=98`,
`max_rr_gap_s=1.8`, `rmssd=32.7`, `sdnn=50.5`, `pnn50=13.3`,
`lnrmssd=3.49`. The self-compare validator smoke passed only with
`external_reference=0` and `gate_b_pass=0`; Gate B remains
`reference_pending` until an external RR/IBI reference agrees within `+/-5 ms`.

**Phase B update 2026-06-14 reference-validator honesty guard:** the HRV and HR
reference validators now reject same-file WHOOP-vs-WHOOP comparisons by default
so parser smokes cannot be mistaken for external validation. Use
`--allow-self-compare` only for parser-smoke checks; the output still reports
`external_reference=0` and `gate_b_pass=0`/`gate_d_pass=0`. Physical iPhone
evidence in
`docs/evidence/gate-b/20260614T-reference-validator-honesty-guard-device-verify/`
built, installed, launched, exported a ready saved RR package, and pulled the
CSV/manifest. The device log showed `rr_reference_package status=ok raw=347
kept=317 conf=91 max_rr_gap_s=2.8 rmssd=50.2 sdnn=54.1 pnn50=28.2
lnrmssd=3.92 reference_validated=0`; Gate B status stayed
`reference_pending`. The default same-file validator run failed with
`reason=same_file_not_external_reference` and `gate_b_pass=0`, while the
explicit parser smoke returned `status=parser_smoke_pass`,
`external_reference=0`, and `gate_b_pass=0`.

**Phase B update 2026-06-14 current active RR export attempt:** a one-shot
physical-device run attempted `--whoop-export-rr-reference-package` again after
the Long Wear default changes. Evidence in
`docs/evidence/gate-b/20260614T-gate-b-rr-reference-package-attempt/` built,
installed, launched, and did not pull a new package
(`WHOOPDBG_REFERENCE_PULL_SKIPPED=missing_reference_package_path`). The current
active journal at launch had only `63s` duration and `67` RR values, with
`active_journal_rr_max_gap_s=8.7` and `active_journal_rr_coverage_3s_percent=71`,
so it is correctly below the strict `300s`, no `>3s` gap Gate B contract. This
does not invalidate the earlier ready saved RR package; it rules out retrying
the current fragment and keeps Gate B focused on external RR comparison plus
stored-session fallback for blackout periods.

**Phase B update 2026-06-14 seeded/timer capture hardening:** the capture path
now seeds a new recording from already archived real RR and recomputes HRV from
a 1-second timer as well as from BLE packet arrivals. This fixes the execution
bug where a nearly complete clean window could be missed because the app waited
for the next RR packet after the 300-second boundary. Physical iPhone evidence
in `docs/evidence/gate-b/20260614T-seeded-timer-capture-device-verify/` built,
installed, launched, and pulled a CSV containing `rr_seed`, `hrv_seed`, and
`hrv_timer` rows. The run still did not pass as a fresh live capture because the
strap stopped emitting standard `2A37` RR for about `33s` near the 5-minute
mark (`capture_quality_reset reason=rr_gap_over_3s`,
`max_rr_log_gap_s=33.3`, `ready_windows=0`). This is the correct result:
phone-side storage/chunking can preserve real RR already received, but it cannot
recover intervals absent from HR-only BLE notifications. The Gate B action item
is therefore external reference comparison for the saved ready package, plus
historical/stored-session fallback for blackout periods, not more START retry
policy.

**Phase B update 2026-06-14 strict-live beat-gap verification:** the capture
path now has an explicit strict live mode (`--strict-live-rr-capture`) that
disables pre-capture RR archive seeding, measures timeout from the latest clean
window after any quality reset, and uses reconstructed RR beat timestamps for
capture gap checks instead of raw BLE notification arrival cadence when real
intervals exist. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T143646Z-strict-live-rr-beat-gap-device-verify/`
built, installed, launched, and ran a 430-second standard `2A37` capture. The
short start gate was clean (`fraction=1.000`, `rr_frames=20`,
`max_rr_gap_s=1.1`) and HealthKit write permission was also reverified in the
same run (`healthkit_export status=saved ... hr_samples=355 workouts=0
hrv_samples=0`). The full Gate B window still failed honestly:
`standard_2a37_frames=440`, `standard_2a37_rr_frames=259`,
`standard_2a37_rr_values=342`, `capture_quality_resets=5`,
`max_rr_log_gap_s=33.1`, final `last_standard_2a37_rrnum=0`,
`hrv_ready=False`, and `capture_summary_ready=False`. This rejects a pure
parser/timestamp bug as the remaining blocker for this run. Live HRV remains
`learning`; next Gate B work should use saved ready RR package reference
comparison and stored-session fallback evidence instead of more live retry
loops.

**Phase B update 2026-06-14 beat-timeline RR gate:** the pre-capture
auto-gate now also uses reconstructed RR beat timestamps when real `2A37`/`0x28`
intervals exist, and logs the raw frame gap separately as
`frame_max_rr_gap_s`. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T151533Z-beat-timeline-rr-gate-device-verify/`
built, installed, launched, and ran a 390-second standard-HR-only capture. The
run received real `2A37` RR (`standard_2a37_frames=394`,
`standard_2a37_rr_frames=159`, `standard_2a37_rr_values=217`), but the
beat-timeline gate correctly refused to start HRV capture:
`auto_capture_start=False`, `capture_summary_ready=False`, and
`max_rr_log_gap_s=60.4`. Gate logs showed the distinction, for example
`max_rr_gap_s=22.7 frame_max_rr_gap_s=7.1 beat_timeline=1` and later
`max_rr_gap_s=3.8 frame_max_rr_gap_s=3.9 beat_timeline=1`, all with
`gap_ok=0`. This rules out a pure BLE-notification batching false negative for
this run; the decoded RR beat timeline itself still had gaps over the 3-second
Gate B contract. HRV remains `learning`.

**Phase H update 2026-06-14 historical usability verifier:** added
`tools/analyze_historical_usability.py` to make stored-transfer evidence
actionable instead of ambiguous. It reports codec validity, live overlap,
overlap with pulled `sessions.json`, and a final `metric_usable` verdict. The
physical-iPhone run in
`docs/evidence/gate-h/20260614T-historical-usability-device-verify/` built,
installed, launched, pulled the current on-device sessions, and ran history-only
`1400,6000,1600`. The strap emitted `2810` historical `0x2f` frames and every
frame passed `whoop_codec.py`; the `whoof` HR/RR layout produced `135` clean old
5-minute RR-shaped windows. This proves the historical-transfer subpath is real.
It still does not feed metrics: the downloaded range was
`2026-03-29T18:44:57Z...19:28:41Z`, had `live_history_overlap=0`, overlapped
none of the `46` saved local sessions, and the verifier emitted
`current_session_usable=0`, `rr_layout_validated=0`,
`external_rr_reference_validated=0`, `metric_usable=0`.

**Phase H update 2026-06-14 NOOP-style history ACK:** after a read-only
cross-check of `NoopApp/noop` and `madhursatija/whoof`, the app now has a
selectable `enddata` ACK mode. `trim` remains the default/known path; `enddata`
ACKs `HISTORY_END` with `[0x01] + body[10..<18]` and write-with-response. The
physical-iPhone run in
`docs/evidence/gate-h/20260614T-history-enddata-ack-device-verify/` built,
installed, launched, logged repeated
`historyAck mode=enddata ... payload=01<8-byte-end-data> write_mode=wr` rows,
and every confirmed write returned `ok`. The strap accepted the ACKs and emitted
`3160` codec-clean historical frames. It still selected old history
(`2026-03-29T19:28:03Z...20:16:45Z`) with no live or saved-session overlap, so
the ACK form is not the current-session selector blocker. Next Gate H work
should focus on NOOP's fuller clock/init/data-range start flow or structured
historical sensor decoding.

**Phase H update 2026-06-14 NOOP backfill preset:** the launcher now has
`--history-noop-backfill` for the concrete NOOP/WHoof-derived path:
history-only, no default `0x22`, init/start sweep `1400,6000,1600`, confirmed
writes, `enddata` ACKs, automatic log, and a 180-second physical-device window.
An initial device run in
`docs/evidence/gate-h/20260614T-noop-backfill-preset-device-verify/` exposed a
launcher bug: the preset requested confirmed writes but the mode was only passed
when an unrelated probe command/sweep was also present, so init logged
`mode=wwr`. That run still verified transfer mechanics (`2491` codec-clean
`0x2f` frames) but remained non-current
(`2026-03-29T20:16:29Z...20:55:06Z`, `current_session_usable=0`). After fixing
the launcher, the confirmed physical-iPhone run in
`docs/evidence/gate-h/20260614T-noop-backfill-confirmed-init-device-verify/`
built, installed, launched, logged `historyOnly ... mode=wr` and
`historyInitSweep ... mode=wr`, accepted repeated `enddata` ACKs, and emitted
`3453` codec-clean historical frames. The `whoof` historical layout is now
strongly plausible as a stored RR interpretation (`3711` RR values,
`hr_mae_bpm=4.94`, `ready_windows=2878`, best 300-second window
`raw=371 kept=371 conf=100 max_rr_gap_s=0.961 rmssd_ms=36.0`), but it still
downloaded old March history (`2026-03-29T20:54:58Z...21:49:00Z`) with
`live_history_overlap=0`, `saved_overlap_seconds=0`, and `metric_usable=0`.
This rules out write mode, ACK shape, and the clean NOOP init sequence as the
current-session selector blockers. Stop blind iterations on this exact path;
use it as a packaged diagnostic/backfill tool only if a new selector clue
appears, while Gate B remains external-reference pending for live/saved RR.

**Phase H steering note 2026-06-14 from NOOP/WHoof cross-check:** the next
software-useful historical step is durable, versioned local historical storage,
not more blind selector churn. Mirror NOOP's safer shape: decode rows, archive
undecodable sensor frames, persist a trim/cursor, and ACK only after local
persistence succeeds. Store `layout_version`, HR/RR hypothesis fields, gravity
or raw sensor fields when decoded, and explicit `current_session_usable` /
`metric_usable` flags. This does not solve current-session selection by itself,
but it prevents repeated transfer work and gives Gate E a path toward
motion-gated workout/sleep detection once gravity is validated.

**Phase H update 2026-06-14 historical archive:** durable local historical
storage is implemented in `Documents/whoop-historical/historical-archive.jsonl`
as JSONL rows with `schema`, `layoutVersion`, raw payload hex, WHOOP/WHoof RR
hypothesis fields, and explicit `metricUsable=false` /
`currentSessionUsable=false` flags. The app logs `WHOOPDBG historicalArchive`
and skips future `0x17` continuation ACKs if local persistence fails. The
launcher now supports `--pull-historical`, and
`tools/analyze_historical_archive.py` verifies the pulled archive. Physical
iPhone evidence in
`docs/evidence/gate-h/20260614T-historical-archive-device-verify/` built,
installed, launched, ran `--history-noop-backfill`, persisted and pulled `2311`
historical rows, and logged archive progress with `failures=0`. Independent
analysis remained honest: `codec_ok_frames=2311`, but the range was still old
March history (`2026-03-29T21:48:45Z...22:24:29Z`), with
`current_session_usable=0`, `metric_usable=0`, and `live_history_overlap=0`.
This is a Gate H storage/robustness slice, not a new-sensor or historical-HRV
pass.

**Phase H update 2026-06-14 archive status:** the app now inspects the
on-device historical archive during `--whoop-log-gate-status` and reports
`historical_archive_local`, parse health, row/byte counts, schema/layout labels,
raw-payload rows, undecodable rows, usable-row counts, and Unix range directly in
the Gate H `WHOOPDBG gate_status` row. Physical iPhone evidence in
`docs/evidence/gate-h/20260614T-historical-archive-status-device-verify/`
built, installed, launched, pulled sessions and the archive, and confirmed
`historical_archive_local=1`, `historical_archive_parse_ok=1`,
`historical_archive_rows=2333`, `historical_archive_metric_usable=0`, and
`historical_archive_current_usable=0`. The refreshed analyzer now prints
`archive_persisted=1`, `metric_ready=0`, `current_session_ready=0`, and
`ready=0` to avoid ambiguous readiness language. This keeps Gate H partial:
the archive is locally durable and codec/protocol useful, but no stored metric or
new sensor is validated. A source cross-check against NOOP/WHoof also reinforced
the current execution shape: ACK `0x17` only after durable local storage, treat
`[0x01] + endData[10:18]` as the stronger continuation clue, and keep gravity,
SpO2, skin-temperature, respiratory, and PPG offsets version-gated until a
current/overlapping segment can be validated.

**Phase H update 2026-06-14 historical download exit:** the historical-download
protocol exit is now physically verified on adidshaft's iPhone, while metric use
remains fail-closed. Evidence in
`docs/evidence/gate-h/20260614T-gate-h-protocol-exit-device-verify/` built
successfully, installed/launched through `live_device_debug.sh`, ran the
NOOP-backed history path, and pulled the on-device archive. The run streamed
`2755` new historical `0x2f` frames, all codec-clean
(`codec_ok_frames=2755`, `codec_bad_frames=0`), and the archive now contains
`5092` persisted rows with raw payloads. The tightened archive analyzer reports
`archive_persisted=1`, `stored_transfer_verified=1`, and
`gate_h_protocol_exit_ready=1`, but also
`gate_h_current_session_metric_ready=0` and `ready=0` because the range is old
and non-overlapping (`reason=historical_old_or_nonoverlapping_saved_sessions`).
A follow-up status launch in
`docs/evidence/gate-h/20260614T-gate-h-protocol-exit-poststatus/` confirmed the
app itself sees `historical_archive_rows=5092`, `metric_usable=0`, and
`current_usable=0`. This satisfies the Gate H historical-download/protocol
expansion exit, not Gate B HRV, not current-session stored metrics, and not a
new sensor decode.

**Phase H status semantics 2026-06-14:** the app and blocker analyzer now track
the protocol exit separately from metric usability. On-device Gate H status is
`ready` only for the protocol-expansion requirement when the local archive
exists, parses, includes raw `0x2f` payload rows, and has zero undecodable rows.
The same evidence row remains explicitly fail-closed for metrics with
`historical_rr_metric_ready=0`, `historical_metric_fail_closed=1`,
`historical_archive_metric_usable=0`, and
`historical_archive_current_usable=0`. No HRV, Recovery, Sleep, Workout, Trends,
or HealthKit path may consume historical rows until current-session overlap and
external validation are proven.

**Gate status update 2026-06-14 full-protocol fast status:** after adding the
full-protocol reset, the current physical-iPhone status run in
`docs/evidence/gate-status/20260614T-full-protocol-fast-status/` built,
installed, launched, discarded a restored peripheral for fresh scan, wrote and
verified a `76`-session backup, pulled the current store and historical archive,
and logged Gate H as `ready` with `gate_h_protocol_exit_ready=1`,
`historical_archive_rows=5192`, and `historical_archive_undecodable_rows=0`.
This does not unlock metrics: `historical_archive_metric_usable=0` and
`historical_archive_current_usable=0`, so historical rows remain fail-closed.
The current hard blockers are now: B external RR reference, C 0/7
reference-validated HRV baseline, D external HR rest-to-max validation, E real
sustained workout evidence, F real 7/30/90-day coverage plus HRV reference, and
G HealthKit-capable signing/widget/complication targets.

**Phase H update 2026-06-14 Atria post-rename backfill:** the app rename gave
Atria a fresh app container, so a first post-rename status launch correctly
reported Gate H as `partial` with `historical_archive_reason=missing_archive`.
The physical-iPhone run in
`docs/evidence/gate-h/20260614T-atria-historical-backfill-device-verify/` then
rebuilt/installed/launched Atria in full-protocol mode, ran the NOOP-style
historical backfill path, and pulled
`Documents/whoop-historical/historical-archive.jsonl` from the current Atria
container. The strap returned `350` historical `0x2f` frames, all persisted as
schema-3 JSONL rows with `undecodable_rows=0`,
`noop_historical_gravity_validated_rows=350`, and `archive_persisted=1`. A
post-backfill status launch in
`docs/evidence/gate-h/20260614T-atria-gate-h-post-backfill-status/` verified
the app now logs `gate_status gate=H status=ready` with
`gate_h_protocol_exit_ready=1`. Metrics remain explicitly barred:
`historical_archive_metric_usable=0`, `historical_archive_current_usable=0`,
and the pulled archive is old/non-overlapping with saved sessions
(`saved_best_separation_seconds=6481756`). This revalidates the Gate H protocol
exit for Atria without promoting historical HRV, Recovery, Sleep, Workout,
Trends, widgets, notifications, or HealthKit.

**Phase H/E update 2026-06-14 NOOP historical gravity pivot:** direct inspection
of NOOP confirmed that WHOOP 4 historical records can carry the motion evidence
we need for sleep confidence: v24 records decode real Unix, HR, RR, and float32
gravity; v25 records decode real Unix plus i16 gravity even when per-second HR is
not stored. The app archive is upgraded to schema 3 with NOOP-compatible gravity
fields, physically-plausible gravity row counts, and snapped stale-clock
correction diagnostics. The Mac archive analyzer cross-checked the existing
pulled archive and found `hist_versions=24,25` with
`noop_historical_gravity_validated_rows=5089/5092`; this is strong historical
motion evidence but remains fail-closed because the prior pull lacked clock
correlation and still reported no current-session overlap. The next useful
physical run is not another live START retry; it is a historical backfill with
`--history-clock-handshake`, then verify whether corrected historical rows
overlap the current saved session before allowing any sleep/workout repair.

**Phase H update 2026-06-14 NOOP clock/backfill override:** the history-only
probe now overrides persisted standard-HR-only mode for explicit protocol runs,
so long-wear settings no longer mask `61080003/04/05/07` subscriptions or
`61080002` command writes. Physical iPhone evidence in
`docs/evidence/gate-h/20260614T032719Z-clock-policy-noop-backfill-override-device-verify/`
built, installed, launched, subscribed to the custom service, sent NOOP-style
`SET_CLOCK`/`GET_CLOCK` plus `1400,6000,1600`, and pulled the on-device archive.
The run logged `cmd_response_count=5`, `clock_correlation_present=1`,
`clock_offset_s=6`, `historical_2f_frames=50`, `codec_ok_frames=50`,
`stored_transfer_verified=1`, and `gate_h_protocol_exit_ready=1`. It remains
metric-blocked: the selected range was `2026-03-29T23:07:05Z...23:07:53Z`,
`current_session_usable=0`, `metric_usable=0`, and `ready=0`. This fixes an
execution bug and verifies the NOOP clock/backfill path, but it still does not
provide current-session HRV, workout repair, sleep repair, trends, or HealthKit
data.

**Phase H update 2026-06-14 schema-3 backfill overlap check:** a follow-up
physical iPhone run in
`docs/evidence/gate-h/20260614T050402Z-schema3-noop-backfill-current-overlap-check/`
kept the WHOOP 4.0 strap on-wrist, built/launched on the cabled iPhone, sent the
NOOP clock/backfill path, and pulled both the historical archive and current
`sessions.json`. The archive analyzer now compares pulled JSONL rows directly
against saved sessions because quiet console runs can show `historical_2f_frames=0`
even when the on-device archive has rows. Evidence: the archive grew to `5192`
rows (`schemas=1,2,3`), `hist_versions=24,25`, and
`noop_historical_gravity_validated_rows=5189/5192`; the clock reference was
healthy (`clock_offset_s=5`), so the corrected archive range remained
`2026-03-29T23:07:10Z...23:07:59Z`. It had zero overlap with `74` saved local
sessions (`saved_best_separation_seconds=6482000.0`), so
`archive_current_session_overlap=0`, `archive_current_session_ready=0`, and
`archive_overlap_reason=archive_old_or_nonoverlapping_saved_sessions`. This
rules out using the current local historical archive to patch the gym workout,
sleep, HRV, Recovery, Trends, or HealthKit. The next fast execution decision is
to move non-overlapping historical rows out of the metric path and only revisit
historical metrics if a new selector or official-app evidence produces a
current-overlapping archive range.

**Phase H update 2026-06-14 fresh protocol-exit reverify:** with the physical
iPhone cabled and the WHOOP 4.0 strap on-wrist, the current Atria build was
installed/launched in full-protocol history-only mode in
`docs/evidence/gate-h/20260614T170211Z-gate-h-fresh-protocol-exit-device-verify-long/`.
The run sent the NOOP/WHoof-derived clock/init/download sequence
(`SET_CLOCK`, `GET_CLOCK`, `0x14 [00]`, `0x60 [00]`, `0x16 [00]`) and accepted
`0x17` trim continuation ACKs. The strap returned `378` fresh `0x2f`
historical frames on `61080005`, all validated by `whoop_codec.py`
(`codec_ok_frames=378`, `codec_bad_frames=0`, `declared_len_mismatches=0`).
The pulled on-device archive now contains `728` schema-3 rows with raw payloads,
`undecodable_rows=0`, and `noop_historical_gravity_validated_rows=728/728`, so
Gate H remains ready for the historical-download/protocol-expansion exit. It
still must not feed metrics: the selected history is old and non-overlapping
(`2026-03-29T23:07:06Z...23:17:19Z`,
`saved_overlap_seconds=0.0`, `metric_usable=0`), so HRV, Recovery, Sleep,
Workout, Trends, widgets, notifications, and HealthKit remain fail-closed for
historical rows until a current-overlapping transfer and external reference are
proven.

**Phase E update 2026-06-14 low-radio app mode:** workout/sleep HR collection no
longer depends on remembering a Mac-only launch preset. The app now has a
persisted `Low radio HR` toggle that selects standard `2A37` HR/RR plus battery,
reconnects on mode changes, skips WHOOP custom streams in standard-only mode,
and logs `radio_mode` in `local_status`. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T000449Z-low-radio-init-device-verify/` built,
installed, launched, and verified the launch-order fix: the first useful status
row already had `radio_mode=standard_hr_only`; the run produced
`standard_2a37_frames=41`, `standard_2a37_rr_values=42`,
`notify_61080005=False`, and `frame_61080005_count=0`. This is the cleaner path
for future long wear and may reduce Bluetooth pressure with AirPods, but it does
not pass Gate E. The pulled store still reports `ready=0`,
`aggregate_ready=0`, `near_miss=1`, with the best saved aggregate blocked by
`stream_gaps_and_hr_below_threshold`.

**Phase E update 2026-06-14 long-wear app mode:** the next unattended path is now
armed from the app itself. `Long wear` and `live_device_debug.sh
--long-wear-mode` persist `whoop.longWear.enabled`, force low-radio
`standard_hr_only`, schedule 60-second checkpoints, schedule 15-second live
workout diagnostics, and run strict workout auto-save only after the existing
sustained-workout detector is ready. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T001408Z-long-wear-mode-device-verify/` built,
installed, launched, and logged `long_wear_mode enabled=1`,
`checkpoint_interval_s=60`, `live_workout_interval_s=15`,
`workout_autosave_interval_s=15`, and `radio_mode=standard_hr_only`. The first
Long wear checkpoint saved `samples=62`, `rr_samples=54`, `hr_raw_2a37=62`,
`hr_accepted=62`, `hr_raw_gaps=0`, `hr_accepted_gaps=0`, and `duration_s=59`;
custom realtime stayed disabled (`frame_61080005_count=0`) while standard HR/RR
continued (`standard_2a37_frames=80`, `standard_2a37_rr_values=69`). This still
does not pass Gate E. The pulled current store reports `ready=0`,
`aggregate_ready=0`, `near_miss=1`, and the best workout aggregate remains
blocked by `stream_gaps_and_hr_below_threshold` with only
`stream_coverage_percent=21`. The next Gate E work should attack persistence and
coverage across real gym interruptions while keeping the detector strict.

**Phase B/E update 2026-06-14 full-protocol reset:** Long wear intentionally
persists low-radio `standard_hr_only` for stable HR collection, but that setting
also suppresses custom WHOOP notify streams and realtime START on later Gate B/H
launches. The app and harness now expose `--full-protocol-mode` /
`--whoop-full-protocol-mode`, which clears persisted Long wear + Low radio HR,
cancels Long wear timers, discards any CoreBluetooth-restored peripheral, and
reconnects from a fresh advertisement in full-protocol mode before
characteristic discovery. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T075916Z-full-protocol-reset-device-verify.md`
verified `ble_restore status=discarded reason=full_protocol_fresh_scan`,
`ble_link status=connected`, `notify_61080005=True`, `realtime_start=True`,
`cmd_response=True`, and `frame_61080005=True`. The one smoke realtime frame had
`rrnum=0`, so HRV remains `learning`; this is the required first step before any
protocol, historical-download, or live-HRV validation run after unattended long
wear, not a Gate B pass.

**Phase E update 2026-06-14 reconnect watchdog:** the app now hardens the
out-of-range path that most likely damaged the real gym capture. Fresh attaches,
state-restoration reconnects, and post-disconnect reconnects arm a 20-second
watchdog; if the same peripheral remains stuck in `connecting`, the app records
a link failure, cancels the stale connection, clears the stale peripheral, and
returns to fresh scan-and-connect. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-reconnect-watchdog-device-verify/` built,
installed, launched, restored the strap as connected, and verified low-radio
Long wear still streams cleanly: `standard_2a37_frames=66`,
`standard_2a37_rr_values=67`, `frame_61080005_count=0`, live
`stream_coverage_percent=100`, `hr_raw_gaps=0`, and `hr_accepted_gaps=0`. The
first checkpoint saved `samples=62`, `rr_samples=62`, and `duration_s=59`.
The watchdog did not naturally fire in this short run because restore succeeded,
so this is coverage hardening rather than a Gate E pass. Current-store replay
still reports `ready=0`, `aggregate_ready=0`, and the best aggregate blocked by
`stream_gaps_and_hr_below_threshold` with `stream_coverage_percent=20`. The next
coverage fix is a durable active-session journal so state restoration or relaunch
resumes the same logical workout instead of restarting live samples from zero.

**Phase E update 2026-06-14 Long Wear fresh-disconnect policy:** Long Wear now
uses fresh scan-and-connect after any disconnect instead of reconnecting the same
`CBPeripheral`. This matches the strap connection contract and targets the
real-gym failure mode where adidshaft moved out of Bluetooth range and the stream
later showed large accepted-HR gaps. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-long-wear-fresh-disconnect-policy-device-verify/`
built, installed, launched, and logged
`long_wear_mode ... disconnect_reconnect_policy=fresh_scan`. A follow-up stream
run verified the low-radio channel still restored and flowed:
`standard_2a37_frames=90`, `standard_2a37_rr_frames=80`,
`standard_2a37_rr_values=81`, `last_rr_quality_source=2a37`, and
`frame_61080003/04/05/07_count=0`. The same evidence surfaced a `39.8s` startup
accepted-HR gap after CoreBluetooth restoration, so this phase is recovery
hardening rather than a Gate E pass. Gate E remains partial with
`workout_days=0`, `workout_saved_ready=0`, and the saved replay still blocked by
`stream_gaps_and_hr_below_threshold`.

**Phase E update 2026-06-14 no-data watchdog:** long-wear collection now also
handles the NOOP-style stale stream case: the app may be connected while
standard `2A37` notifications silently stop. Long wear schedules a watchdog with
`timeout_s=30` and `interval_s=15`; on stale data it checkpoints the real samples
already collected, marks stale recovery, cancels the stale peripheral, and falls
back to fresh scan-and-connect. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-no-data-watchdog-device-verify/` built,
installed, launched, and logged
`no_data_watchdog schedule timeout_s=30.0 interval_s=15.0`. The watchdog did not
fire because the short run stayed healthy: `standard_2a37_frames=72`,
`standard_2a37_rr_values=69`, `frame_61080005_count=0`, live
`stream_coverage_percent=100`, `hr_raw_gaps=0`, and `hr_accepted_gaps=0`. This
does not pass Gate E. It prevents a future connected-but-silent HR stream from
quietly destroying coverage, while the current store still reports `ready=0`,
`aggregate_ready=0`, and the best aggregate blocked by
`stream_gaps_and_hr_below_threshold` with `stream_coverage_percent=20`.

**Phase E update 2026-06-14 active session journal:** the app no longer relies on
RAM alone for the in-progress Long wear session. Accepted standard `2A37` HR
samples are written locally to `Documents/whoop-active-session.json` every small
batch and before checkpoint/diagnostic decisions. On Long wear launch/restoration,
the app reloads the same live session ID, samples, rolling HR display, and
session-quality counters; `local_status` and Gate E evidence now include
`active_journal_present`, `active_journal_samples`, `active_journal_age_s`, and
`active_journal_duration_s`. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-active-session-journal-device-verify/` built,
installed, launched, and verified a two-launch restore: phase 1 saved
`active_session_journal status=saved ... samples=42 duration_s=40` with
`standard_2a37_frames=45`, `standard_2a37_rr_values=44`, and
`frame_61080005_count=0`; phase 2 relaunched, restored
`active_session_journal status=restored reason=persisted samples=70 duration_s=74`
with `age_s=5`, and immediately logged `live_workout_samples=70` instead of
starting from zero. Gate E remains partial: the status line still reports
`workout_saved_ready=0` and
`workout_best_blocker=stream_gaps_and_hr_below_threshold`, so no workout is being
fabricated from missing elevated-HR data.

**Phase E update 2026-06-14 active journal lifecycle flush:** Long wear now
force-saves the active-session journal on scene inactive/background and
app-termination notifications, and the cabled-device harness exposes
`--flush-active-journal-after N` to verify the same save path on a real phone.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-active-journal-lifecycle-flush-device-verify/`
built, installed, launched, and logged
`active_session_journal debug_flush_schedule delay_s=8.0`, then
`active_session_journal status=saved reason=debug_timer samples=693
duration_s=743`. Normal accepted-HR persistence continued afterward with
`samples=710 duration_s=759`, the low-radio contract held
(`frame_61080005_count=0`), and standard `2A37` kept flowing
(`standard_2a37_frames=26`, `standard_2a37_rr_values=25`). Gate E remains
partial: saved workout replay still reports `saved_workout_ready=0` with
`saved_workout_peak_hr=120`, `saved_workout_threshold_hr=121`, and
`saved_workout_stream_coverage_percent=21`, so the remaining work is data
coverage/deduplication and a real sustained elevated-HR workout, not synthetic
classification.

**Phase E update 2026-06-14 durable session-store upsert:** final saves no
longer silently insert duplicate same-ID rows or clear the active Long wear
journal before durable storage is confirmed. `SessionStore.add` now upserts by
`SavedSession.id`, store writes return success/failure, finish paths log
`store_failed` if persistence fails, and `ActiveSessionJournal.clear()` happens
only after a confirmed save. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-session-store-durable-upsert-device-verify/`
built, installed, launched, restored `active_session_journal ... samples=986
duration_s=1042`, then logged `session_store_save status=ok op=add mode=replace
... samples=986 duration_s=1042` followed by
`active_session_journal status=cleared reason=session_auto_save`. A fresh Long
wear journal then started and persisted `samples=25 duration_s=23`, with
low-radio still held (`frame_61080005_count=0`,
`standard_2a37_rr_values=24`). This removes an app-side double-count/data-loss
failure mode, but Gate E remains partial because the saved workout replay is
still a near miss rather than a sustained elevated-HR workout.

**Phase E update 2026-06-14 saved replay de-dupe:** existing duplicate same-ID
rows are now removed from replay in memory without deleting raw local history.
Workout replay, aggregate workout/sleep candidates, daily rollups, and today
strain use canonical saved sessions by ID, preferring the longest/newest row.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-replay-dedupe-device-verify/` built, installed,
launched, and logged `workout_replay_summary raw_sessions=69
canonical_sessions=68`. Gate E stayed honest after de-dupe:
`workout_saved_ready=0`, `near_miss=1`, `stream_coverage_percent=23`,
`threshold_gap_bpm=1`, and `stream_gaps_and_hr_below_threshold`. This rules out
same-ID duplicate inflation as the remaining blocker; the remaining workout
blocker is real captured-data continuity and sustained elevated HR.

**Phase B/E update 2026-06-14 active journal RR persistence:** the active Long
wear journal now stores real standard `2A37` RR intervals as well as accepted HR
samples and restores them into the live RR archive after relaunch. Physical
iPhone evidence in
`docs/evidence/gate-b/20260614T-active-journal-rr-persistence-device-verify/`
built, installed, launched, and verified the full path: phase 1 saw
`standard_2a37_rr_values=3` and saved
`active_session_journal status=saved ... rr_values=2`; phase 2 relaunched and
restored `active_session_journal status=restored reason=persisted samples=808
rr_values=11 duration_s=881 age_s=3`, surfaced
`active_journal_rr_values=11` in `local_status`, then continued to save
`rr_values=22` from live `2A37`. Low-radio mode held
(`frame_61080005_count=0`). This closes an app-side RR data-loss path for
unattended long wear and lets future saved-session checkpoints retain RR already
captured before relaunch. It is not a Gate B clinical pass: saved RR remains
external-reference pending, and Gate E remains partial until a real sustained
elevated-HR workout validates.

**Phase E update 2026-06-14 workout audit wrapper:** `gate_e_workout_audit.sh`
now turns a post-workout return into one deterministic local command: build,
install, launch, low-radio HR-only capture by default, strict checkpoint and
auto-save wiring, delayed validation, current `sessions.json` pull, verified
backup pull, WHOOPDBG log analysis, saved-store replay, and `summary.txt`.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-workout-audit-wrapper-device-verify/`
verified the wrapper with a short smoke. The run built and installed on the
cabled iPhone, pulled the current store and backup, and the corrected all-label
log analyzer reported `missing=none`, `backup_verified=1`,
`gate_e_workout_ready=0`, `workout_saved_ready=0`, and
`primary_blocker=stream_gaps_and_hr_below_threshold`. Store replay had
`sessions=69`, `ready=0`, `aggregate_ready=0`, `near_miss=1`; the best aggregate
remained `Long wear + 4 chunks` with `stream_coverage_percent=25`, `peak=120`,
`threshold=121`, and `elevated_s=0`. This phase does not pass Gate E; it removes
manual post-run interpretation as a bottleneck and keeps the detector honest for
the next real elevated-HR workout.

**Phase E update 2026-06-14 borderline workout diagnostic:** saved workout
replay, threshold sensitivity, Local Status, Gate E status, and the workout
analyzers now carry diagnostic-only `borderline_*` evidence for samples within
`5 bpm` below the selected HR threshold. Borderline evidence uses the same
gap-bounded sustained-bout logic as the real detector and never increments
`workout_days` or passes Gate E. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-borderline-workout-diagnostic-device-verify/`
built, installed, launched, and logged the current best aggregate as
`ready=0`, `near_miss=1`, `threshold_hr=121`, `peak_hr=120`,
`elevated_s=0/1200`, and `longest_bout_s=0/480`. The borderline HRR50 view
lowered the diagnostic threshold to `116`, but still found only
`borderline_elevated_s=14` with a `9s` longest bout. HRR35/40/45/50 sensitivity
also stayed `ready_fractions=none`; even HRR35 had only `92s` strict elevated
time against `353s` required and a `44s` longest bout. This rules out a simple
one-bpm threshold cliff as the cause of the failed gym detection. Gate E remains
partial; the remaining workout blockers are low captured HR and large stream
gaps during the real attempt.

**Phase E update 2026-06-14 historical gap-repair diagnostic:** Local Status and
Gate E diagnostics now expose fail-closed `historical_gap_repair_*` fields. The
app compares the best saved workout attempt's start/end with the on-device
historical archive range and reports overlap, separation, current usable rows,
and metric usability without ever using historical rows to pass Gate E. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-historical-gap-repair-diagnostic-device-verify/`
built, installed, launched, and logged the current best aggregate as
`saved_workout_ready=0`, `saved_workout_stream_coverage_percent=30`,
`saved_workout_peak_hr=120`, `saved_workout_threshold_hr=121`, and
`saved_workout_dropped_gap_s=14744`. The historical repair decision stayed
`historical_gap_repair_status=fail_closed` with
`historical_gap_repair_reason=no_workout_overlap`,
`historical_gap_repair_overlap_s=0`, `historical_gap_repair_separation_s=6556603`,
`historical_gap_repair_current_usable_rows=0`, and
`historical_gap_repair_metric_usable=0`. This rules out using the existing
historical archive to patch the failed gym workout; Gate E remains partial and
the correct next path is a cleaner continuous real-workout capture, not
backfilling non-overlapping history.

**Phase E update 2026-06-14 workout window ruling:** after the schema-3
historical archive proved non-overlapping, the pulled physical-iPhone
`sessions.json` was replayed through the strict workout analyzer in
`docs/evidence/gate-e/20260614T051347Z-workout-window-ruling/`. The analyzer
evaluated `74` sessions, `599` single-session windows, `6` aggregate candidates,
and `1090` aggregate windows. No strict HRR50 candidate passed
(`total_ready=0`). Diagnostic sensitivity also ruled out a hidden good workout:
even at HRR35 the best aggregate had `peak=120`, `threshold=100`,
`elevated_s=230`, `required_elevated_s=1200`, `longest_bout_s=89`,
`required_bout_s=480`, and `stream_coverage_percent=35`. At HRR50 the best
candidate remained a near miss with `peak=120`, `threshold=121`, and
`elevated_s=0`. This rules out a detector/windowing/local-storage bug for the
gym data. Gate E remains partial because the received wrist-HR signal and
coverage do not contain a passable workout; the next useful work is a cleaner
continuous workout capture or an external HR reference proving under-reporting.

**Gate execution update 2026-06-14 post-ruling status checkpoint:** after
ruling out historical repair and hidden workout windows, a fresh physical-iPhone
status run in
`docs/evidence/gate-status/20260614T051559Z-post-ruling-current-status/`
built, installed, launched, logged the current local store, verified backup
integrity, and pulled `sessions.json`. The short launch did not emit explicit
`WHOOPDBG gate_status` rows, so `tools/analyze_gate_status.py` now synthesizes a
fallback status table from `local_status`, daily rollups, trend windows, widget
snapshot, and backup verification. Current blocker table: Gate B
`external_rr_reference`; Gate C `validated_hrv_baseline_0/7`; Gate D
`external_hr_rest_to_max_validation`; Gate E
`near_miss:stream_gaps_and_hr_below_threshold`; Gate F
`coverage_2pct_hrv_gated_1`; Gate G
`healthkit_entitlement,widget_target,complication_target`; Gate H `ready` for
protocol download but `metric_fail_closed`. The store now has `sessions=74`,
`days=2`, `backup_current=1`, `sleep_days=2` low-confidence HR-only, and no
accepted workouts. This confirms the fast path: stop retrying current historical
repair for this data; move only when there is a cleaner workout capture,
external HR/RR reference, HealthKit-capable signing profile, or enough real
calendar history.

**Gate execution update 2026-06-14 fast gate-status path:** `--whoop-log-gate-status`
now emits a lightweight, explicit blocker table before replay-heavy RR/workout
forensics run, and `WhoopAppApp` calls it before BLE launch automation. The
harness also logs the exact `devicectl` launch command and starts its runtime
timer after CoreDevice confirms launch, so missing launch arguments are no
longer ambiguous. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T052919Z-fast-gate-status-device-verify/`
built, installed, launched, verified backup integrity, pulled `sessions.json`,
and logged explicit `gate_status_summary mode=fast deep_replay=0` plus rows for
local and Gates A-H. Current store: `sessions=74`, `days=2`, `rest_hr=52`,
`healthkit_hr_samples=38696`, `healthkit_workouts=74`, `saved_rr_samples=18051`,
`sleep_days=2`, and `workout_days=0`. The blocker table now comes from real
gate rows instead of analyzer fallback: Gate B `external_rr_reference`, Gate C
`validated_hrv_baseline_0/7`, Gate D `external_hr_rest_to_max_validation`, Gate
E `deep_replay_required_for_best_candidate` in fast mode, Gate F
`coverage_2pct_hrv_gated_1`, Gate G
`healthkit_entitlement,widget_target,complication_target`, and Gate H `ready`
for protocol download but `metric_fail_closed`. Deep replay remains available
with `--whoop-log-gate-status-deep`; the normal status command is intentionally
cheap so every future physical-device phase can start with a reliable blocker
table.

**Gate execution update 2026-06-14 Gate E fast replay blockers:** the fast
Gate E row now runs the bounded saved-workout replay before logging status
instead of emitting `bounded_deep_replay_pending`. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-fast-status-workout-replay-device-verify/`
built, installed, launched with `--full-protocol-mode --log-gate-status`,
verified backup integrity (`sessions=76`, digest match), pulled
`sessions.json`, and logged `gate_status gate=E status=partial` with the real
best saved workout blocker. The current best aggregate is
`workout_best_source=aggregate_chunks`, `workout_best_chunks=30`,
`workout_best_stream_coverage_percent=29`, `workout_best_dropped_gap_s=29078`,
`workout_best_threshold_gap_bpm=0`, `workout_best_elevated_s=3`,
`workout_best_longest_bout_s=3`, and `workout_best_required_bout_s=480`.
Historical gap repair stayed fail-closed:
`historical_gap_repair_status=fail_closed`,
`historical_gap_repair_reason=no_workout_overlap`, and
`historical_gap_repair_metric_usable=0`. This rules out a hidden fast-status
analysis gap for the captured gym data; Gate E remains partial because the
stored wrist-HR evidence does not contain a sustained elevated-HR workout.

**Gate execution update 2026-06-14 in-app gate readiness:** the Local Status
card now surfaces a compact A-H readiness strip using the same fail-closed
diagnostics as the gate-status logger. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T-gate-readiness-ui-device-verify/` built,
installed, launched with `--full-protocol-mode --log-gate-status`, connected to
the strap, subscribed to `61080005`, and logged
`WHOOPDBG gate_readiness_ui gates=8 ready=1`. The row matched the canonical
gate blockers: A `runtime`, B `reference_pending[external_rr_reference]`,
C `learning[validated_hrv_baseline_0_of_7]`, D
`partial[external_hr_rest_to_max_validation]`, E
`partial[near_miss_stream_gaps]`, F `learning[coverage_2pct_hrv_gated]`, G
`partial[healthkit_entitlement+widget_target+complication_target]`, and H
`ready[metric_fail_closed]`. This does not pass additional gates; it makes the
app itself show the shortest honest path forward and reduces repeated console
triage.

**Gate execution update 2026-06-14 bounded deep gate-status:** the launcher now
supports `--log-gate-status-deep`, forwarding
`--whoop-log-gate-status-deep` after the normal fast status flag. The app keeps
the initial `gate_status_summary` and Gates A-H rows fast, explicitly marks
Gate B RR-ledger replay as `skipped_bounded_deep_status`, then emits a separate
`gate_status gate=E.deep` row plus `workout_replay_summary`,
`workout_threshold_sensitivity_summary`, `historical_gap_repair`, and
`gate_status_deep`. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T074436Z-bounded-deep-gate-status-device-verify/`
built, installed, launched, verified backup integrity, and pulled the current
container. The deep replay found no accepted workout: best candidate is
`aggregate_chunks`, `chunks=29`, `stream_coverage_percent=29`, `peak_hr=120`,
`threshold_hr=121`, `threshold_gap_bpm=1`, `elevated_s=0`,
`required_elevated_s=1200`, `longest_bout_s=0`, and
`dropped_gap_s=28742`. Analyzer output now merges `E.deep`, so Gate E reports
`near_miss:stream_gaps_and_hr_below_threshold` rather than the fast placeholder.
This rules out a hidden pass in the current store while preserving the detector
thresholds and the no-fake-workout rule.

**Phase E update 2026-06-14 active journal RR continuity:** Local Status and
the Gate E log analyzer now expose RR continuity for the active Long wear
journal so chunk/local-storage repair ideas can be ruled in or out with real
data. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-active-journal-rr-continuity-device-verify/`
built, installed, launched, and logged the current journal as
`active_journal_rr_values=1554`, `active_journal_rr_max_gap_s=124.6`,
`active_journal_rr_gap_over_3s=85`, `active_journal_rr_gap_over_5s=73`, and
`active_journal_rr_coverage_3s_percent=53`. The same Local Status line reported
the saved workout aggregate as `saved_workout_stream_coverage_percent=32`,
`saved_workout_peak_hr=120`, `saved_workout_threshold_hr=121`,
`saved_workout_elevated_s=0`, and blocker
`stream_gaps_and_hr_below_threshold`. This is a negative but decisive result:
RR cannot honestly fill the current workout gaps, and the current attempt stays
near-miss/learning unless a cleaner historical backfill channel is decoded.

**Phase E update 2026-06-14 accepted-HR watchdog:** Long wear now watches
accepted HR sample freshness separately from raw BLE notification freshness. If
accepted HR is stale for 12s while connected, it checkpoints the current real
samples, force-flushes the active journal, and reconnects via fresh scan; if raw
notifications are still arriving with zero-contact status, it logs
`stale_contact` and waits rather than reconnecting for a fit problem. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-accepted-hr-watchdog-device-verify/` built,
installed, launched, and verified the watchdog is armed:
`accepted_hr_watchdog schedule timeout_s=12.0 interval_s=15.0` and
`long_wear_mode ... accepted_hr_timeout_s=12 ...
disconnect_reconnect_policy=fresh_scan`. The existing workout aggregate remains
learning (`stream_coverage_percent=32`, `peak_hr=120`, `threshold_hr=121`,
`elevated_s=0`); this phase prevents future accepted-HR stalls from silently
ruining coverage.

**Phase E update 2026-06-14 accepted-HR watchdog forced verification:** the app
and launcher now support a device-only verifier:
`--force-accepted-hr-watchdog-after N` / `--whoop-force-accepted-hr-watchdog-after
N`. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-accepted-hr-watchdog-forced-device-verify-2/`
logged `accepted_hr_watchdog debug_force_schedule delay_s=5.0`; the console
ended before the delayed `status=forced` row was captured, so the verification
uses the post-action Local Status row instead. That row proves the recovery
outcome: `checkpoint_last_status=saved_accepted_hr_watchdog`,
`checkpoint_last_samples=2589`, `checkpoint_last_duration_s=3030`,
`ble_link_disconnects=1`, `ble_link_successes=2`, and
`ble_link_last_autosave=saved`. This verifies checkpoint, active-journal flush,
and fresh-scan reconnect on the cabled iPhone. It is still not a Gate E pass:
the saved aggregate remains near-miss/learning with `stream_coverage_percent=33`,
`peak_hr=120`, `threshold_hr=121`, and `elevated_s=0`.

**Phase E update 2026-06-14 windowed workout replay:** saved workout replay now
checks workout-sized windows inside long sessions and aggregate chunks instead
of only scoring a whole all-day Long wear span. This keeps the production
detector unchanged: HRR50 threshold, real HR only, stream coverage, elevated
seconds, and continuous-bout gates. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-windowed-workout-replay-device-verify-3/`
built, installed, launched, and logged `source=windowed_workout` candidates on
device. The pulled-store analyzer found `windows=520`, `window_ready=0`,
`aggregate_windows=879`, `aggregate_window_ready=0`, and `total_ready=0`.
The current gym data still does not pass: best production evidence remains
`peak=120`, `threshold=121`, `elevated_s=0`, and
`primary_blocker=stream_gaps_and_hr_below_threshold`. This rules out whole-day
aggregate dilution as the only blocker and keeps Gate E partial.

**Phase E update 2026-06-14 active-journal audit path:** the Gate E workout
audit wrapper and `tools/analyze_workout_store.py` now pull and analyze
`Documents/whoop-active-session.json` alongside saved `sessions.json`. The
active journal is reported as a separate `active_journal` candidate and is not
merged into aggregate chunks, so the current Long Wear segment is visible
without double-counting overlapping checkpoints. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-active-journal-audit-wrapper-device-verify/`
built, installed, launched, pulled the current store, pulled the active journal
(`active_journal_pull_status=ok`), and verified the store analyzer reports
`active_journal=1`. The active candidate remained fail-closed:
`active_journal_ready=0`, `duration_s=1676`, `observed_s=950`,
`dropped_gap_s=726`, `stream_coverage_percent=57`, `peak=120`,
`threshold=121`, and `elevated_s=0`. Gate E remains partial, but post-workout
execution now sees both committed history and the still-running journal.

**Phase E update 2026-06-14 current-store forensics and HR-continuity
watchdog:** after the long/gym wear, the current device store was pulled before
another relaunch/build and analyzed with active-journal support. Evidence in
`docs/evidence/gate-e/20260614T033509Z-current-device-store-forensics/` shows
`sessions=71`, `active_journal=1`, `total_ready=0`, and best aggregate
`Long wear + 4 chunks` at `stream_coverage_percent=37`, `p95=87`, `p99=106`,
`peak=120`, `threshold=121`, `samples_above_threshold=0`,
`samples_above_borderline=44`, and
`failure_class=hr_signal_below_workout_band`; the active journal peaked at
`87` bpm. This rejects parser failure, missing-pull tooling, aggregate dilution,
and a one-bpm threshold cliff as sufficient explanations for that workout
attempt. The app now attacks the remaining capture-continuity issue earlier:
Long wear caches the standard Heart Rate Measurement characteristic and, after
`3.5s` of stale `2A37` HR while connected in standard-HR-only mode, reasserts
notify and reads when possible. The last action is persisted so detached
physical-device runs can be verified after the fact. Physical iPhone evidence
in
`docs/evidence/gate-e/20260614T043504Z-hr-continuity-watchdog-detached-device-verify/`
built, installed, launched detached, confirmed the process stayed alive, and
then logged the persisted result on device:
`hr_continuity_watchdog ... status=forced ... action=reassert_notify
notifying=1`; the analyzer reported `hr_continuity_watchdog_actions=1`. This is
future-capture hardening, not a Gate E pass: no workout is counted until a real
sustained elevated-HR workout passes the existing detector on the physical
iPhone.

**Phase E update 2026-06-14 saved-workout gap diagnosis + startup defer:**
Local Status now reports the best saved workout candidate's explicit
`saved_workout_capture_diagnosis`, `saved_workout_capture_action`,
`saved_workout_max_gap_s`, and `saved_workout_gap_count`, and the Gate E log
analyzer parses the same fields. The dashboard defers heavy saved replay, trend
preview, and strain-validation diagnostics for 20 seconds after launch so BLE
fresh-scan connect/notify/START is not starved by a large current store.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-saved-workout-gap-diagnosis-device-verify/`
built, installed, launched, connected fresh, subscribed to `61080005`, `2A37`,
and battery, received realtime START ACK, then logged the deferred Local Status
blocker: `saved_workout_capture_diagnosis=fragmented_stream`,
`saved_workout_stream_coverage_percent=29`,
`saved_workout_dropped_gap_s=29078`, `saved_workout_max_gap_s=7336.0`, and
`saved_workout_gap_count=808`. Gate E remains partial with
`saved_workout_ready=0`; this rules the current saved workout data in as a
capture-continuity failure rather than a hidden detector pass.

**Phase E update 2026-06-14 long-wear log budget:** Long Wear/standard-HR-only
capture now reduces foreground log and dashboard pressure: `standardHR payload`
logs emit the first five frames and then at most once per minute with
`suppressed_since_last=N`, full packet logging remains opt-in through
`--whoop-log-ble-frames`, `strain_explain`/`strain_zone_summary` are time-gated,
and Local Status de-dupe ignores active-journal age while still logging age in
the emitted evidence row. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-standard-hr-log-budget-device-verify/` built,
installed, launched Long Wear, subscribed to `2A37`, and recorded only `6`
`standardHR payload` lines, `2` `strain_explain` lines, and `1` `local_status`
line over a 75-second capture while still saving a real checkpoint:
`samples=287`, `rr_samples=227`, `hr_raw_2a37=287`, `hr_accepted=287`. Gate E
remains partial; this is capture hardening for future workouts, not a detector
pass.

**Phase E update 2026-06-14 HR watchdog throttle:** Long Wear no longer
reasserts `2A37` notify after ordinary `3.5s` standard-HR delivery gaps. The
HR-continuity watchdog now uses `timeout_s=12` and `interval_s=6`, while the
accepted-HR watchdog remains `12s` and the no-data watchdog remains the fresh
scan reconnect path for longer stalls. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-hr-watchdog-throttle-device-verify/` built,
installed, launched Long Wear, logged
`hr_continuity_watchdog schedule timeout_s=12.0 interval_s=6.0`, emitted only
one `notifyState ch=2A37` row, emitted zero live
`hr_continuity_watchdog status=stale` rows, and still saved real local data:
`samples=368`, `rr_samples=322`, `hr_raw_2a37=368`, `hr_accepted=368`. Gate E
remains partial; this reduces BLE control traffic and AirPods-adjacent radio
pressure without changing workout/HRV confidence gates.

**Phase E update 2026-06-14 strength-candidate diagnostics:** saved workout
replay now has a diagnostic-only strength-workout lane that can explain
long, fragmented gym evidence without counting it as a workout. `WorkoutReadiness`,
`local_status`, Gate E status, aggregate workout logs, workout validation, and
`tools/analyze_workout_store.py` now emit `strength_candidate`,
`strength_candidate_reason`, `strength_diagnostic_only=1`, and `next_action`.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-strength-candidate-diagnostic-device-verify/`
built, installed, launched, connected BLE, subscribed to `61080005` and `2A37`,
sent realtime START, received `cmdResp`, and logged
`workout_strength_candidate=1`. The current gym block remains `Gate E partial`:
best source `aggregate_chunks`, `31` chunks, `stream_coverage_percent=27`,
`duration_s=45718`, `observed_s=12291`, `dropped_gap_s=33427`, `peak_hr=122`,
`threshold_hr=121`, `elevated_s=3`, `borderline_elevated_s=57`, and
`next_action=fix_stream_continuity_before_counting`. No workout is counted from
this evidence because real sustained elevated-HR continuity is absent.

**Phase E update 2026-06-14 workout HR distribution:** workout readiness now
logs HR distribution shape (`p90`, `p95`, `p99`) and sample counts above the
personalized threshold/borderline threshold. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T162640Z-workout-hr-distribution-device-verify/`
built, installed, launched, reconnected to the strap, and verified the current
gym aggregate on device. The best stitched block had strong sample volume
(`hr_accepted=19085`) and workable stitched coverage (`85%`), but the HR shape
was not a sustained workout: `p90=82`, `p95=91`, `p99=106`,
`threshold_hr=121`, only `5` samples above threshold, `63` above borderline,
`elevated_s=3`, and `longest_bout_s=3`. Threshold sensitivity stayed
fail-closed even at HRR35 (`ready_candidates=0`, `elevated_s=395`,
`required_elevated_s=1200`, `longest_bout_s=101`, `required_bout_s=480`).
This rules out a simple threshold/logging bug for this capture: Gate E remains
partial because the saved gym evidence does not contain sustained elevated HR,
not because Atria is hiding a valid workout.

**Phase E update 2026-06-14 dual blocker action:** workout next-action logic now
returns `fix_stream_continuity_and_validate_intensity` when a candidate has both
stream gaps and peak HR below the personalized HRR threshold. Physical iPhone
evidence in
`docs/evidence/gate-e/20260614T142048Z-workout-dual-blocker-action-device-verify/`
built, installed, launched, and verified the new label on aggregate/windowed
candidates with `primary_blocker=stream_gaps_and_hr_below_threshold`. The
selected best saved aggregate still reports `workout_next_action=
fix_stream_continuity_before_counting` because that specific candidate crossed
the 121 bpm threshold (`peak_hr=122`) and is stream-limited, so Gate E remains
partial with `workout_days=0`. The same run showed a useful Gate B clue,
`standard_2a37_frames=53`, `standard_2a37_rr_frames=53`,
`standard_2a37_rr_values=69`, and `rr_quality source=2a37 state=ready
fraction=1.000 ... max_rr_gap_s=2.8`, but it is not a Gate B pass because the
required 300s/reference RMSSD comparison is still missing.

**Phase E update 2026-06-14 default Long Wear bootstrap:** normal app launches
now self-arm the production capture path once: Long Wear enabled, standard
`2A37` HR-only radio, 60-second checkpoints, 15-second workout diagnostics,
15-second strict workout auto-save checks, and stale-stream watchdogs. Explicit
`--whoop-full-protocol-mode` still disables this for Gate B/H protocol work, and
user toggles mark the defaults as configured so the app does not keep
re-enabling after a manual choice. `WhoopAppApp` now applies BLE automation and
persistent Long Wear before gate/daily/status logs, so Gate rows report the
actual active capture mode. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-default-long-wear-bootstrap-device-verify/`
reset only capture defaults, launched normally, and logged
`capture_defaults status=enabled ... reason=first_normal_launch`,
`radio_mode mode=standard_hr_only`, `long_wear_mode enabled=1`,
`checkpoint_interval_s=60`, `checkpoint_source=long_wear`,
`notifyState ch=2A37`, real `session_checkpoint status=saved`, and summary
`notify_61080005=False`, `realtime_start=False`, `frame_61080005=False`.
Gate E remains partial; this hardens future unattended workout/sleep capture
without relaxing sustained-HR workout criteria or fabricating old gym evidence.

**Phase E update 2026-06-14 long-gap chunk rollover:** Long Wear now treats a
`>=120s` standard `2A37` sample gap as a segment boundary. It saves the old
active session, clears the active journal, and starts the next received HR
sample in a clean live segment. This is the local chunking path for
foreground/debug interruptions: missing HR stays missing in saved history, but
future live detection is no longer poisoned by one stale mega-session. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-long-gap-rollover-device-verify/` showed
`active_session_rollover status=saved ... gap_s=120.7`, followed by fresh live
diagnostics at `stream_coverage_percent=100`, `dropped_gap_s=0`,
`hr_raw_gaps=0`, and a clean 60-second checkpoint. Gate E remains partial
because the old gym aggregate is still a low-confidence HR-only near miss.

**Phase E update 2026-06-14 stale-gap boundary tightening:** after the current
sleep/workout status run, the active Long Wear session showed a relaunch gap
being carried forward into live workout coverage (`hr_sample_gap ... gap_s=60.8`
and later `hr_max_raw_gap_s=70.2`), even though any gap above the 5-second
continuity limit already fails workout readiness. The segment boundary is now
`>=30s` instead of `>=120s`, so debug relaunches, BLE stalls, or short
out-of-range periods start a fresh active segment before poisoning the next live
window. This still does not estimate missing HR or make old workout aggregates
pass; it improves future capture hygiene while keeping gaps fail-closed.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-current-sleep-workout-status/` exposed
the stale segment (`active_journal_duration_s=153`,
`active_journal_rr_coverage_3s_percent=71`) while confirming the latest
overnight low-HR sleep candidate (`sleep_validation status=ready`,
`duration_s=10801`, `avg_hr=58`, `confidence=low`). Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-30s-gap-rollover-device-verify/`
verified the fix: `active_session_rollover ... gap_s=60.8 threshold_s=30.0`,
then fresh live diagnostics with `stream_coverage_percent=100`,
`dropped_gap_s=0`, `hr_raw_gaps=0`, and active RR coverage back to `100`.

**Phase E update 2026-06-14 stale-journal restore close:** Long Wear now applies
the same `30s` stale boundary during active-journal restore, before gate-status
or live-workout diagnostics run. If a persisted journal is already older than
the boundary at launch, the app saves it as a real local session with its HR/RR
diagnostics, clears the journal only after that save path, and starts diagnostics
from a fresh empty segment. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-stale-journal-restore-close-device-verify/`
first caught and fixed a build typo, then verified the green path:
`active_session_journal status=closed reason=stale_restore age_s=136
threshold_s=30.0 samples=70 rr_values=73 duration_s=73
action=start_fresh_before_diagnostics`. The immediate Gate E/local status rows
reported `active_journal_present=0`, so the stale segment no longer appears as
the current live window before first fresh HR. After new `2A37` HR arrived, live
workout diagnostics were clean (`stream_coverage_percent=100`,
`dropped_gap_s=0`, `hr_raw_gaps=0`) and the fresh journal reported
`active_journal_rr_coverage_3s_percent=100`. Gate E remains partial: this fixes
future capture hygiene, but the old gym aggregate is still fail-closed as a
near miss because stream gaps and sustained elevated-HR criteria were not met.

**Phase E update 2026-06-14 HR/workout cadence tolerance:** the post-restore
continuity check in
`docs/evidence/gate-e/20260614T-gate-e-post-restore-continuity-check/` showed
that standard BLE Heart Rate (`2A37`) can pause for short connected intervals
(`8.3s`, `9.4s`, and `5.3s`) while real HR samples continue before and after.
Treating every `>5s` HR notification pause as missing workout time made current
live workout coverage drop from `100%` to the low/mid `80%` range at rest and
misclassified the app-side blocker as stream continuity. The HR/workout coverage
gap limit is now `15s` in both the app and `tools/analyze_workout_store.py`.
This is not an HRV relaxation: RR/HRV keeps the Gate B contract of no `>3s` RR
gap and still reports `learning` when RR continuity is poor. Longer gaps still
remain fail-closed and Long Wear still rolls stale segments at `30s`. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T-gate-e-hr-workout-gap-tolerance-device-verify/`
verified the split: live workout diagnostics stayed at
`stream_coverage_percent=100`, `dropped_gap_s=0`, `hr_raw_gaps=0`, and
`hr_accepted_gaps=0`, while RR quality still reported `state=poor_contact`,
`max_rr_gap_s=60.0`, and `hrv_state=learning`.

**Phase E update 2026-06-14 low-radio fresh-scan recovery:** Long Wear standard
HR mode now logs fresh scan start/match/retry events and arms a fallback scan
after stale accepted-HR/no-data reconnect requests, so the app does not wait
silently if iOS delays a disconnect callback. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T121628Z-low-radio-reconnect-fallback-device-verify/`
built, installed, launched, fresh-scanned, connected, subscribed to `2A37`, and
kept custom protocol off (`notify_61080005=False`, `realtime_start=False`,
`frame_61080005_count=0`). The live Long Wear window reached
`stream_coverage_percent=100` with `147` accepted HR samples over `141s`, no HR
gaps, and a saved checkpoint (`samples=125`, `duration_s=120`). Gate E remains
partial because this was below workout threshold and the older gym aggregate
still fails closed, but the low-radio capture path needed for the next real
workout is now device-verified.

**Phase E update 2026-06-14 forced low-radio reconnect recovery:** the
accepted-HR watchdog recovery path is now physically verified end-to-end.
Evidence in
`docs/evidence/gate-e/20260614T122128Z-forced-low-radio-reconnect-fallback-device-verify/`
forced the watchdog after `25s`, checkpointed the current segment, disconnected,
fresh-scanned, reconnected (`attempts=2`, `successes=2`, `disconnects=1`), and
resumed real standard HR on `2A37`. Post-reconnect live diagnostics showed
`stream_coverage_percent=100`, `samples=45`, `duration_s=41`,
`dropped_gap_s=0`, `hr_raw_gaps=0`, and `hr_accepted_gaps=0`, while custom
traffic stayed off (`notify_61080005=False`, `realtime_start=False`,
`frame_61080005_count=0`). This satisfies the reconnect-survival slice needed
for unattended workout capture; Gate E remains partial until a real sustained
workout is detected and accepted on device.

**Phase E update 2026-06-14 stitched observed workout ranking:** saved workout
replay now adds a `stitched_observed_chunks` candidate for multi-session
clusters and ranks equally strong candidates by real stream coverage before raw
wall-clock span. Long gaps between captured chunks are compressed into explicit
reset markers so unobserved Bluetooth-away time cannot dominate coverage or
elevated-bout math, while still resetting sustained-HR bouts and logging the
gap evidence. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T150654Z-stitched-observed-workout-ranked-device-verify/`
built, installed, launched, and verified the corrected diagnosis:
`aggregate_workout_summary ... best_source=stitched_observed_chunks`,
`best_stream_coverage_percent=85`, `best_blocker=insufficient_elevated_time`,
`best_elevated_s=3`, `best_required_elevated_s=1200`, and
`best_next_action=keep_learning_until_sustained_hr`. `gate_status gate=E.deep`,
`workout_replay_summary`, and `local_status` all reported the same source and
blocker, while `workout_days=0` and `saved_workout_ready=0` kept Gate E
fail-closed. This rules out stream-collapse alone as the current workout
blocker; the saved gym data does not contain a sustained elevated-HR workout
under the HRR50 detector, so the next useful proof is either a cleaner true
elevated workout capture or an independent HR reference showing wrist HR
under-reporting.

**Current gate audit 2026-06-14:** after the Gate B beat-timeline change, a
fresh cabled physical-iPhone audit in
`docs/evidence/gate-status/20260614T152558Z-fresh-all-gates-post-beat-timeline-audit/`
rebuilt, installed, launched, and logged deep gate status, HealthKit export,
widget snapshot, trends, daily rollups, workout replay, backup, and pulled the
current sessions/backups. The canonical readiness row is now
`gate_readiness_ui gates=8 ready=2`: A `runtime_required`, B
`reference_pending[external_rr_reference]`, C
`learning[validated_hrv_baseline_0_of_7]`, D
`partial[independent_hr_reference_missing]`, E
`partial[near_miss_insufficient_elevated_time]`, F
`learning[coverage_2pct_hrv_gated]`, G `ready[none]`, and H
`ready[metric_fail_closed]`. Gate G is verified ready in this run:
HealthKit saved a fresh incremental delta (`hr_samples=432`, `workouts=0`,
`hrv_samples=0`) and readback covered it, widget/app-group/complication
diagnostics were ready, notification cadence stayed confidence-gated, and backup
verify reported `digest_match=1`. Gate H remains ready for the protocol
expansion exit (`historical_download_validated=1`, codec-clean archive rows
present), while historical metrics remain barred (`historical_metric_fail_closed=1`).
The audit confirms the app is not stuck on stale platform blockers; remaining
work is clinical reference validation, validated HRV baseline collection, a real
sustained elevated workout or independent HR reference, and enough real trend
history.

**Phase B update 2026-06-14 on-device RR reference validator:** Atria now has a
device-side debug path for the remaining clinical HRV blocker. Launching with
`--whoop-validate-rr-reference` exports the best saved WHOOP RR window, looks
for an independent RR/IBI CSV at `Documents/atria-reference/rr-reference.csv`,
applies the same Gate B correction contract to the reference side, compares
RMSSD with a `+/-5 ms` tolerance, and rejects same-content copies of Atria's own
WHOOP export as `same_content_not_external_reference`. Physical iPhone evidence
in
`docs/evidence/gate-b/20260614T153533Z-on-device-rr-reference-validator-final/`
built, installed, launched, connected to the strap in standard-HR-only mode, and
exported a ready WHOOP RR package (`raw=368`, `kept=361`, `conf=98`,
`max_rr_gap_s=1.8`, `rmssd=32.7`). The validator then correctly logged
`rr_reference_validation status=missing reason=missing_external_reference_file
... gate_b_pass=0 external_reference=0 reference_validated=0`. This does not
pass Gate B; it turns the remaining reference blocker into an explicit on-device
file/validation workflow.

**Phase D update 2026-06-14 on-device HR reference validator:** Atria now has
the matching physical-device validator for the `+/-2 bpm` HR/Strain blocker.
Launching with `--whoop-validate-hr-reference` selects the best saved real
`2A37` HR segment, looks for an independent HR CSV at
`Documents/atria-reference/hr-reference.csv`, rejects same-content copies of
Atria's own export, pairs WHOOP samples to the nearest reference samples within
5 seconds, and requires at least 30 pairs over at least 60 seconds with mean and
max absolute delta within `2 bpm`. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T154423Z-on-device-hr-reference-validator-final/`
built, installed, launched, connected to the strap, exported a WHOOP HR package
from `11236` real `2A37` samples over `10801s` with `100%` observed coverage
(`avg_hr=58.1`, `peak_hr=85`, `resting_hr=47`), and correctly logged
`hr_reference_validation status=missing ... gate_d_pass=0 external_reference=0
reference_validated=0` because no independent HR file was present. Gate D
remains partial until a non-Atria HR reference is supplied and passes.

**Gate B/D update 2026-06-14 reference push workflow:** the cabled-device
launcher now supports `--push-rr-reference /path/to/rr.csv` and
`--push-hr-reference /path/to/hr.csv`, copying Mac-side independent reference
files into `Documents/atria-reference/rr-reference.csv` and
`Documents/atria-reference/hr-reference.csv` before launch. Physical iPhone
evidence in
`docs/evidence/gate-reference/20260614T155030Z-reference-push-smoke/` includes
a green physical-device `xcodebuild`, then installed the app, copied both smoke
CSVs, launched, exported the current WHOOP-side RR/HR reference packages, and
verified the validators consume pushed files without passing bad data. The
intentionally tiny smoke RR
file failed with `rr_reference_validation status=fail reason=reference_window
... gate_b_pass=0 external_reference=1 reference_validated=0`; the intentionally
tiny smoke HR file failed with `hr_reference_validation status=fail
reason=insufficient_pairs ... gate_d_pass=0 external_reference=1
reference_validated=0`. This does not advance Gate B or Gate D to ready; it
turns the remaining external-reference step into a one-command, on-device,
fail-closed workflow. Real reference CSVs overwrite the smoke files.

**Gate B/D update 2026-06-14 reference cleanup workflow:** Atria now supports
`--whoop-clear-reference-inputs`, exposed in the launcher as
`--clear-reference-inputs`, to delete `Documents/atria-reference/rr-reference.csv`
and `Documents/atria-reference/hr-reference.csv` before export/validation runs.
Physical iPhone evidence in
`docs/evidence/gate-reference/20260614T155714Z-reference-clear-device-verify/`
includes a green physical-device `xcodebuild`, installed and launched the app,
logged `reference_inputs_clear status=ok removed=2 missing=0 failed=0`, then
proved the validators returned to missing-reference fail-closed status:
`hr_reference_validation status=missing ... gate_d_pass=0 external_reference=0`
and `rr_reference_validation status=missing ... gate_b_pass=0
external_reference=0`. This clears parser-smoke or stale inputs without
uninstalling the app or deleting local sessions.

**Gate B/D update 2026-06-14 reference validation persistence:** Atria now
persists successful external-reference validation instead of only logging it.
If an independent RR CSV passes the Gate B `+/-5 ms` RMSSD comparison, the
matching saved session is marked `hrvReferenceValidated=true`, its RMSSD is
stored, and the validated value can feed the HRV baseline, Recovery, trends,
HealthKit HRV export, and Gate B status. If an independent HR CSV passes the
Gate D `+/-2 bpm` comparison, Atria stores a local `csv` HR-reference pass and
uses it alongside HealthKit independent-HR audit state in strain validation,
Gate D os_log, and the readiness UI. Physical iPhone evidence in
`docs/evidence/gate-reference/20260614T160455Z-reference-validation-persistence-failclosed/`
includes a green physical-device `xcodebuild`, installed and launched the app,
cleared missing reference inputs, exported current WHOOP-side reference packages,
and verified fail-closed behavior remained intact:
`rr_reference_validation status=missing ... gate_b_pass=0 reference_validated=0`,
`hr_reference_validation status=missing ... gate_d_pass=0 reference_validated=0`,
`gate_status gate=B ... reference_validated=0`, and
`gate_status gate=D ... csv_external_hr_reference_ready=0
external_hr_reference_source=missing`. This does not pass Gate B or Gate D
without independent reference data; it removes the state-machine bug that would
have made a future real pass invisible.

**Gate D update 2026-06-14 HealthKit reference hardening:** HealthKit
independent-HR presence is no longer treated as HR validation. The HealthKit
reference audit now pairs saved Atria HR samples to non-Atria HealthKit HR
samples within 5 seconds and requires the same Gate D `+/-2 bpm` comparison
contract used by the CSV validator: at least 30 pairs over at least 60 seconds,
mean absolute delta <= 2 bpm, and max absolute delta <= 2 bpm. Legacy
`externalReferenceReady` defaults are ignored unless the persisted paired
comparison has `reason=ready` and enough in-tolerance pairs. Physical iPhone
evidence in
`docs/evidence/gate-d/20260614T161039Z-healthkit-reference-validation-hardening/`
built and installed on the cabled iPhone, wrote/read back Atria HR samples in
HealthKit (`healthkit_export_verify status=ok ... readback_atria_hr_samples=43971`),
then failed closed for external HR validation because HealthKit had no
independent samples:
`healthkit_reference_audit ... independent_hr_samples=0 pairs=0
reference_validated=0 external_reference_ready=0
validation_reason=independent_reference_missing`. A follow-up on-device launch
confirmed Gate D now reports
`healthkit_reference_reason=independent_reference_missing`,
`healthkit_reference_pairs=0`, and `healthkit_external_reference_ready=0`.
Gate D remains partial until a real independent HR source is present and passes
the paired tolerance check.

**Gate D update 2026-06-15 HealthKit manual-entry rejection:** the HealthKit
independent-HR audit now explicitly rejects Apple Health heart-rate samples with
`HKMetadataKeyWasUserEntered=true` before pairing against Atria HR. Manual rows
still count in total HealthKit HR, but they are logged as
`user_entered_hr_samples` / `rejected_user_entered_hr_samples` and never enter
`independent_hr_samples`, so a typed Apple Health value cannot become a fake
Gate D reference. Physical iPhone evidence in
`docs/evidence/gate-d/20260615T-healthkit-user-entered-filter-device-verify/`
built, installed, launched Atria, ran the HealthKit reference audit, and logged
`healthkit_reference_audit status=ok ... independent_candidate_hr_samples=0
user_entered_hr_samples=0 rejected_user_entered_hr_samples=0
independent_hr_samples=0 ... external_reference_ready=0
validation_reason=independent_reference_missing`. Gate D status persisted the
same counters with `healthkit_user_entered_hr_samples=0` and
`healthkit_rejected_user_entered_hr_samples=0`. This does not pass Gate D; it
closes another non-sensor reference path while preserving the external HR
reference requirement.

**Phase G update 2026-06-14 Atria identity hardening:** The main iOS app plist
now explicitly pins `CFBundleDisplayName` and `CFBundleName` to `Atria`, matching
the installed app product name and widget display name. The BLE device-name
fallback for an unnamed strap now displays `Strap` instead of a product/protocol
brand. Internal protocol/debug identifiers such as `WHOOPDBG`, BLE UUID names,
and `--whoop-*` harness flags remain unchanged because they are evidence and
automation surfaces, not user-facing app branding.

**Phase E update 2026-06-14 low-confidence sleep UI hardening:** The local
status tile and Gate E readiness UI no longer mark sleep evidence as ready just
because an HR-only sleep candidate exists. `sleep_state=low-confidence` remains
visible as evidence, but the green/ready state now requires a future
`ready`/`validated` sleep state. Gate E blockers combine the sleep blocker with
the current workout blocker, so a future workout pass cannot accidentally hide
that sleep still lacks validated motion/IMU evidence or an explicitly accepted
fallback.

**Phase C update 2026-06-14 Recovery readiness state fix:** The Gate C readiness
row now checks the same state emitted by `localStatus`: high-confidence Recovery
is represented as `ready`, not `high`. This prevents a future validated
Recovery baseline from remaining visually stuck in `learning` after the required
7-day HRV baseline and confidence gate are satisfied. The current device still
correctly reports Gate C as learning because validated HRV baseline coverage is
`0/7`.

**Gate B update 2026-06-14 HRV display reference gate:** The main HRV card no
longer displays the live `ble.hrv` RMSSD as the headline value unless an
external RR reference has validated a saved HRV session. A clean live RR window
without reference validation now shows `pending`/`reference pending` in the main
card while preserving RR-count/confidence diagnostics. The app logs
`WHOOPDBG hrv_display ... live_rmssd_hidden=1` when live HRV is ready but hidden
behind the external-reference gate. This keeps the user-facing metric aligned
with Gate B: real RR collection can be working while clinical HRV remains
reference-pending.

**Phase G update 2026-06-14 HealthKit full-gate honesty:** Gate G status now
separates platform plumbing from metric completion. Backup, HealthKit
entitlement/availability, notifications, widget, and app-group support can be
`platform_ready=1`, but the gate remains `partial` while HRV is blocked by the
external RR reference gate or workouts are still learning. The Gate G evidence
now reports `metric_blockers=healthkit_hrv_reference_pending` and/or
`healthkit_workout_learning` instead of marking the entire platform gate ready
just because the plumbing is available.

**Phase B update 2026-06-14 RR artifact honesty:** Standard `2A37` RR
intervals now carry the same-packet HR into the clinical HRV analyzer. The
analyzer keeps the original Gate B correction contract (keep 300-2000 ms and
drop >20% delta artifacts), and adds a stricter counted rejection bucket for
`rejected_hr_mismatch`: an RR interval is excluded from HRV if its implied BPM
differs from the same packet's HR by more than 35 bpm. The raw RR remains
archived for audit, the interval still counts in `raw`, and confidence remains
`kept/raw`. On-device diagnostic evidence confirms the rule rejects the
synthetic 317 ms / HR 75 artifact while leaving Gate B `reference_pending`
until a real 5-minute window is externally validated.

**Gate execution update 2026-06-14 execution-priority checkpoint:** Atria now
emits a single on-device `WHOOPDBG execution_priority` line after gate-status
logging so the next session can avoid looping on already ruled-out work.
Physical iPhone evidence in
`docs/evidence/gate-status/20260614T170810Z-execution-priority-device-verify/`
built, installed, launched, pulled the current session store, and logged:
`next_gate=E`,
`next_action=run_low_radio_sustained_workout_capture_not_protocol_retry`,
`external_blocked=B:external_rr_reference,C:validated_hrv_baseline_0_of_7,D:external_hr_reference`,
`real_world_needed=E:real_sustained_workout,F:more_real_history_or_hrv_reference`,
`local_blocked=G:healthkit_hrv_reference_pending+healthkit_workout_learning,H:historical_metrics_fail_closed`,
and `ready=H:historical_protocol_exit`. This checkpoint explicitly skips START
retry churn, blind historical selectors, and fake metrics; the next actionable
work is Gate E low-radio sustained workout capture once the strap and phone are
available.

**Gate execution update 2026-06-14 historical-ready alignment:** `docs/evidence/gate-status/20260614T183328Z-execution-priority-historical-ready-alignment/` keeps Gate H's protocol exit clear. The cabled physical iPhone run logged `gate_status gate=H status=ready` with `historical_download_validated=1` and `gate_h_protocol_exit_ready=1`; `execution_priority` now reports `ready=H:historical_protocol_exit`, moves `H:historical_metrics_fail_closed` to `diagnostic_only`, and leaves `local_blocked` to actual unfinished local work: `G:healthkit_hrv_reference_pending+healthkit_workout_learning`. Historical metrics remain fail-closed and barred from HRV/Workout math, but they no longer contradict the Gate H exit.

**Phase E update 2026-06-14 broad workout-window replay:** Atria now mirrors the
offline analyzer's broad workout-window strategy on device: 5-minute-spaced
windows from 10 to 90 minutes are replayed across saved chunks, then the
existing HRR50, observed-duration, gap, elevated-seconds, and continuous-bout
gates are applied unchanged. The implementation uses indexed windows so deep
gate-status logging completes on the physical iPhone, and both app and analyzer
now report p95/p99 HR plus samples above threshold/borderline. The analyzer's
HRR threshold rounding was corrected to match Swift, so rest `52` and max HR
`189` produce the same HRR50 threshold (`121 bpm`) in both tools. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T171800Z-broad-workout-window-optimized-device-verify/`
built, installed, launched, and logged `workout_replay_summary ... sessions=915
ready=0 ... best_source=stitched_observed_chunks ... stream_coverage_percent=85
... p95_hr=91 p99_hr=106 threshold_hr=121 samples_above_threshold=5
hr_distribution_below_workout_band=1 elevated_s=3 required_elevated_s=1200`.
Offline replay on the pulled store scanned `640` single-session windows and
`1572` aggregate windows with `total_ready=0`. This rules out a missed app
window as the reason the gym data failed; Gate E remains partial, and the next
non-looping action is wrist-HR/profile/reference validation before more workout
captures.

**Gate execution update 2026-06-14 wrist-HR priority alignment:** after broad
Gate E replay proved the old gym data has low wrist-HR distribution rather than
a missed workout window, `WHOOPDBG execution_priority` now reuses the replay's
concrete `bestNextAction` instead of always saying to run another low-radio
workout capture. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T172150Z-execution-priority-wrist-hr-device-verify/`
built, installed, launched, and verified the aligned line:
`execution_priority next_gate=E
next_action=validate_wrist_hr_underreporting_or_profile_before_more_workouts`.
Gate E remains partial and fail-closed; the next productive work is independent
HR/profile validation, not another protocol or generic capture loop.

**Gate D/E update 2026-06-14 HR/profile validation plan:** the app now emits a
focused `WHOOPDBG hr_profile_validation_plan` when broad workout replay proves
the best candidate is below the personalized HRR50 band. The diagnostic logs the
same fail-closed decision variables (`p95_hr`, `p99_hr`, `threshold_hr`,
samples above threshold/borderline, stream coverage, elevated seconds, and
required elevated seconds) plus the exact reference path:
`--export-hr-reference-package`, then an independent
`Documents/atria-reference/hr-reference.csv` or non-Atria HealthKit HR source
followed by `--validate-hr-reference`. This does not pass Gate D or Gate E; it
prevents another blind workout/protocol loop and makes the next proof
independent HR/profile validation. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T172603Z-hr-profile-validation-plan-device-verify/`
verified the new line and exported an Atria HR package. The same run proved
HealthKit permission alone is insufficient: all readable HealthKit HR samples
were Atria-originated (`healthkit_independent_hr_samples=0`), so Gate D correctly
stayed partial with `primary_blocker=independent_reference_missing`.

**Gate D/E update 2026-06-14 HR reference UI:** the dashboard diagnostics now
surface the same reference proof gap on-screen. `SavedWorkoutAttemptStatus`
carries p95/p99 HR and samples-above-threshold into SwiftUI, and the Local
Status panel includes an HR reference card with Atria HR samples, independent HR
samples, validation pairs, and the saved workout's threshold evidence. Physical
iPhone evidence in
`docs/evidence/gate-d/20260614T173043Z-hr-reference-ui-device-verify/` verified
`WHOOPDBG hr_reference_ui state=missing_independent_hr ... workout_p95_hr=91
workout_p99_hr=106 workout_threshold_hr=121 workout_samples_above_threshold=5
workout_elevated_s=3 workout_required_elevated_s=1200`. This is still not a
Gate D or Gate E pass; it makes the correct fail-closed next action visible in
the app.

**Gate D/E update 2026-06-14 in-app HR reference workflow:** the HR reference
card now has Export and Import actions. Export uses the same on-device HR
package builder and exposes the CSV through the share sheet; Import copies a
selected independent CSV into `Documents/atria-reference/hr-reference.csv` and
immediately runs the existing Gate D validator. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T173634Z-hr-reference-import-export-ui-device-verify/`
verified the dashboard export wrapper with `WHOOPDBG hr_reference_export_ui
status=ok` while the package remained `reference_validated=0`. This removes the
Mac-only friction from the reference step without changing the accuracy bar:
Gate D/E remain partial until a true non-Atria HR reference passes.

**Gate B update 2026-06-14 in-app RR reference workflow:** the HRV card now has
Export and Import actions for the external RR/IBI reference step. Export uses
the same saved 300-second RR package builder and exposes the CSV through the
share sheet; Import copies a selected independent RR/IBI CSV into
`Documents/atria-reference/rr-reference.csv` and immediately runs the existing
Gate B validator. Physical iPhone evidence in
`docs/evidence/gate-b/20260614T174320Z-rr-reference-import-export-ui-device-verify/`
verified the dashboard export wrapper with `WHOOPDBG rr_reference_export_ui
status=ok` for a real saved window (`raw=368`, `kept=361`, `conf=98`,
`max_rr_gap_s=1.8`, `rmssd=32.7`) while `reference_validated=0`. This removes
Mac-only friction from the final HRV reference step without changing the
accuracy bar: Gate B remains reference-pending until a true independent RR/IBI
recording passes the `+/-5 ms` RMSSD comparison.

**Gate execution update 2026-06-14 gate-status progress hardening:** deep
gate-status now logs `gate_status_start` and staged `gate_status_progress`
breadcrumbs before and after local rollups, HealthKit diagnostics, workout
replay, historical gap repair, and strain validation. This makes the cabled
execution path fail-loud if a slow diagnostic blocks the canonical gate rows.
Physical iPhone evidence in
`docs/evidence/gate-status/20260614T175427Z-gate-status-progress-device-verify/`
built, installed, launched, and verified the full path: `gate_status_start`
showed `sessions=156`, `rr_samples=22671`, and `hr_accepted=27955`; progress
rows completed through `strain_validation_done`; canonical A-H gate rows and
`execution_priority` followed. Current truth stayed fail-closed: B is
`reference_pending`, C is `learning`, D is `partial` with
`healthkit_independent_hr_samples=0`, E is `partial` with `sleep_days=2` but
`workout_saved_ready=0`, G is `partial` because platform plumbing is ready but
HRV/workout metrics are gated, and H is `ready` for protocol exit while
historical metrics remain fail-closed.

**Gate E update 2026-06-14 workout HR-distribution diagnosis:** core
`WorkoutReadiness` now carries a first-class
`hrDistributionBelowWorkoutBand` flag and routes the next action to
`validate_wrist_hr_underreporting_or_profile_before_more_workouts` when p95 HR
stays below the personalized HRR50 threshold and there is less than 60 seconds
of threshold-band evidence. The same field is logged for aggregate workout
candidates, per-session workout readiness, live workout diagnostics, and
workout auto-save checks, and is shown in the Local Status saved-workout detail.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T180907Z-workout-hr-distribution-diagnosis-device-verify/`
built, installed, launched, and verified the current best 2026-06-14 candidate
as `hr_distribution_below_workout_band=1` with
`next_action=validate_wrist_hr_underreporting_or_profile_before_more_workouts`,
`stream_coverage_percent=85`, `p95_hr=91`, `p99_hr=106`, `threshold_hr=121`,
`samples_above_threshold=5`, and `elevated_s=3/1200`. Gate E remains partial:
the saved gym/day data still must not count as a workout, and the honest next
proof is independent HR/profile validation rather than lowering thresholds or
retrying realtime START policy.

**Gate execution update 2026-06-14 gate-status completion wait:** the cabled
launcher now treats `WHOOPDBG execution_priority` as the normal
`--log-gate-status` completion marker and `WHOOPDBG gate_status_deep` as the
deep-status completion marker. Gate-status launches get a minimum 180-second
deadline, but stop early once the marker arrives; missing markers now fail the
harness with `HARNESS_ERROR=gate_status_incomplete` or
`HARNESS_ERROR=gate_status_deep_incomplete` instead of silently producing a
partial audit. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T181229Z-gate-status-completion-wait-device-verify/`
used a deliberately short `--seconds 20` run and still captured complete A-H
gate rows, `execution_priority`, `gate_status_complete=True`, and
`digest_match=1` backup verification. Current truth stayed fail-closed: B
reference-pending, C learning, D partial for missing independent HR reference,
E partial with the workout next action set to
`validate_wrist_hr_underreporting_or_profile_before_more_workouts`, F learning,
G partial on metric blockers, and H ready for protocol exit while historical
metrics remain fail-closed.

**Gate E update 2026-06-15 workout profile sensitivity diagnostics:** Gate E
now logs a diagnostic-only profile sensitivity calculation for the best saved
workout candidate. The fields
`required_profile_max_hr_for_p95_hrr50`,
`required_profile_max_hr_for_p99_hrr50`,
`required_profile_max_hr_for_peak_hrr50`, and
`current_profile_minus_p99_required_bpm` answer whether the current max-HR
profile could plausibly explain a failed HRR50 workout classification. These
fields are emitted in `gate_status gate=E`, `gate_status gate=E.deep`, and
`hr_profile_validation_plan`. They do not lower thresholds, count a workout, or
replace the external HR reference; Gate D/E still require real sustained HR
evidence or an independent HR reference before passing. Physical iPhone
evidence in
`docs/evidence/gate-e/20260614T184416Z-workout-profile-sensitivity-fast-device-verify/`
verified the fast path with `gate_status_complete=True`, `digest_match=1`,
`profile_max_hr=189`, `required_profile_max_hr_for_p95_hrr50=130`,
`required_profile_max_hr_for_p99_hrr50=160`,
`required_profile_max_hr_for_peak_hrr50=192`, and
`current_profile_minus_p99_required_bpm=29`. The app still reported
`workout_saved_ready=0`, `workout_best_elevated_s=3`, and
`workout_best_required_bout_s=480`, so this update rules out blind profile
churn without pretending the gym data passed.

**Gate D/E update 2026-06-15 HR comparison plan surfaced:** the HR reference
card and `WHOOPDBG hr_reference_ui` now carry the saved workout's p99 HRR
percent, profile-sensitivity gap, and a concrete comparison action. Physical
iPhone evidence in
`docs/evidence/gate-d/20260614T184832Z-hr-comparison-plan-device-verify/`
built, installed, launched, and verified
`hr_reference_ui ... workout_p99_hrr_percent=39
required_profile_max_hr_for_p99_hrr50=160
current_profile_minus_p99_required_bpm=29
hr_comparison_need=p99_below_hrr50_validate_wrist_hr
hr_comparison_action=compare_next_workout_to_independent_hr_reference`. Gate D
and Gate E remain fail-closed (`independent_reference_missing`,
`workout_saved_ready=0`); the app now directs the next real-world attempt toward
an independent HR comparison instead of more detector or profile churn.

**Gate G update 2026-06-15 combined deep-status backup verification:** debug
launch backup write/verify now runs before the deep gate-status audit, and the
desktop harness no longer stops at `gate_status_deep` when explicit side-effect
work such as backup/session pulls was requested. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T191216Z-gate-status-backup-combined-device-verify/`
built, installed, launched, wrote
`Documents/atria-backups/atria-sessions-20260614T191223Z-debug.json`, verified
it with `session_backup_verify status=ok ... digest_match=1`, logged
`gate_status_deep_complete=True`, and pulled both the 5.2 MB backup JSON and
current `sessions.json` from the app container. Gate G still remains partial
because HealthKit HRV/workout exports are correctly blocked by upstream HRV
reference and workout-learning gates, but platform backup evidence is now
captured in the same physical-device deep audit instead of being skipped.

**Gate D/E update 2026-06-15 explicit HealthKit reference audit:** the launcher
now has `--healthkit-reference-audit`, and the app has a matching
`--whoop-healthkit-reference-audit` launch path that runs only the Apple Health
HR reference check and requires a `WHOOPDBG healthkit_reference_audit` result.
It rejects Atria-written samples as self-reference before comparing against the
strict Gate D tolerance. Physical iPhone evidence in
`docs/evidence/gate-d/20260614T191825Z-healthkit-reference-audit-device-verify/`
built, installed, launched, and logged
`healthkit_reference_audit status=ok total_hr_samples=44743
atria_hr_samples=44743 independent_hr_samples=0 independent_sources=none ...
reference_validated=0 validation_reason=independent_reference_missing`, then
pulled current `sessions.json`. This rules out Apple Health on this phone as a
hidden independent HR reference for the existing workout data; Gate D/E still
need an external HR CSV, non-Atria HealthKit HR samples, or a future real
sustained-HR workout before any workout/strain pass can be claimed.

**Gate E update 2026-06-15 strength-candidate steering:** saved workout
classification now lets the diagnostic-only strength candidate steer the next
action before generic HR-reference/profile retry text. UI saved-workout state
also prefers `strength candidate` over `near miss` when both are true. Physical
iPhone evidence in
`docs/evidence/gate-e/20260614T192240Z-strength-candidate-steering-device-verify/`
built, installed, launched, verified backup `digest_match=1`, and logged
`gate_status gate=E ... workout_saved_ready=0 ... workout_strength_candidate=1
... workout_strength_diagnostic_only=1 ...
workout_next_action=observe_strength_signal_without_counting_and_validate_hr_reference`.
`execution_priority` and `workout_replay_summary` now carry the same next
action. Gate E remains partial: this does not count the gym span as a workout,
does not lower HRR50 thresholds, and still requires either a real sustained-HR
workout or an independent HR reference before workout export/strain validation
can pass.

**Gate execution update 2026-06-15 local-action split:** `execution_priority`
now reports `next_local_gate` and `next_local_action` separately from the next
overall gate blocker, so externally/real-world-blocked Gate E no longer looks
like a local code loop. Physical iPhone evidence in
`docs/evidence/gate-status/20260614T192822Z-execution-priority-local-action-device-verify/`
built, installed, launched, logged
`execution_priority next_gate=E
next_action=observe_strength_signal_without_counting_and_validate_hr_reference
next_local_gate=none
next_local_action=no_local_code_unblocker_collect_external_reference_or_real_workout`,
completed gate status, and pulled valid `sessions.json`. Current truth is
unchanged: B/C/D/E/F/G are still incomplete for the previously documented
reference, baseline, real-workout, trend, and HealthKit-workout reasons; H's
protocol exit remains ready with historical metrics fail-closed.

**Gate execution update 2026-06-15 verifier timeout cleanup:** the device
harness now launches `devicectl --console` in its own process group, emits
`HARNESS_CAPTURE_TIMEOUT` when the requested capture window ends, and interrupts
or kills the console process group before post-run pulls. This keeps physical
iPhone verification bounded instead of leaving stale console sessions attached.
Physical iPhone evidence in
`docs/evidence/gate-status/20260614T193344Z-devicectl-timeout-cleanup-device-verify/`
used the already-built app, launched Atria on the cabled iPhone, connected to
the strap in `standard_hr_only`, logged 2A37 RR samples, emitted
`HARNESS_CAPTURE_TIMEOUT seconds=8 launch_seen=1 action=stop_devicectl_console`,
and left no matching `devicectl`/`live_device_debug.sh` process running.

**Gate G update 2026-06-15 HealthKit write after permission:** after Health
write permission was granted on the phone, physical iPhone evidence in
`docs/evidence/gate-g/20260614T193454Z-healthkit-export-after-permission-device-verify/`
launched Atria, ran `--whoop-healthkit-export`, completed gate status, and
pulled valid `sessions.json`. The app logged
`healthkit_export status=saved sessions=169 hr_samples=193 workouts=0
hrv_samples=0 ledger_entries=168 idempotent=1 incremental=1` followed by
`healthkit_export_verify status=ok ... readback_covers_delta=1 ... data_appears=1`.
This proves Atria-written HR appears in Apple Health on the cabled device.
Gate G remains partial, not failed: HRV HealthKit samples and workouts are still
blocked honestly by Gate B's external RR reference and Gate E's workout-learning
state, and HealthKit HR samples are still rejected as an independent HR
reference for Gate D (`independent_hr_samples=0`).

**Gate G update 2026-06-15 metric-gated status:** Gate G now reports
`status=metric_gated` when the platform plumbing is ready but HRV/workout
HealthKit exports are blocked by upstream metric validity. This avoids treating
Apple Health, widget/app-group, backup, or notification plumbing as local
blockers after they have evidence. Physical iPhone evidence in
`docs/evidence/gate-g/20260614T194102Z-metric-gated-status-device-verify/`
built, installed, launched, completed gate status, and pulled valid
`sessions.json`. The device logged `gate_status gate=G status=metric_gated
evidence=platform_ready=1;_metric_blockers=healthkit_hrv_reference_pending+healthkit_workout_learning`
with HealthKit entitlement/readback, app-group widget, widget target,
complication target, backup, and notification diagnostics all present. The UI
diagnostic also logged
`G=metric_gated[platform_ready_metric_blockers:healthkit_hrv_reference_pending+healthkit_workout_learning]`.
Gate G is still not complete; it is now precisely waiting on Gate B HRV
reference validation and Gate E workout readiness before HRV/workout writes can
appear in Apple Health.

**Gate E update 2026-06-15 saved motion in local status:** the dashboard
`local_status` now includes diagnostic motion hints persisted in saved sessions
instead of only reporting the current live BLE manager's motion counters. This
aligns the UI/local status with `gate_status` while keeping sleep confidence
honest: diagnostic hints are still `motion_validated=0` and do not upgrade
HR-only sleep to high confidence. Physical iPhone evidence in
`docs/evidence/gate-e/20260614T194700Z-saved-motion-local-status-device-verify/`
built, installed, launched, completed gate status, and pulled valid
`sessions.json`. The cabled device logged `gate_status gate=local ...
motion_source=diagnostic_observe_only;_motion_hint_sessions=1;_motion_hints=2`
and `local_status ... sleep_state=low-confidence ... motion_source=diagnostic_observe_only
... motion_validated=0 motion_hint_count=2
motion_hint_kinds=motion_short:1,sleepflag:1`. Gate E remains partial because
sleep is still low-confidence and workout detection still requires a real
sustained-HR workout or independent HR reference.

**Gate execution update 2026-06-15 incomplete-status harness reporting:**
`live_device_debug.sh` now keeps its transcript writable until after
post-run completion checks, so an incomplete `--log-gate-status`,
`--log-gate-status-deep`, or HealthKit reference audit emits the intended
`HARNESS_ERROR=...` marker instead of crashing with a Python closed-file
traceback. This is a verification reliability fix only: it does not advance any
metric gate, but it preserves honest failing evidence for physical-device runs
and replay triage.

**Gate execution checkpoint 2026-06-15 post-harness audit:** after the harness
fix, `docs/evidence/gate-status/20260614T195549Z-post-harness-clean-gate-status/`
completed a fast physical-iPhone gate-status run and pulled valid
`sessions.json`. The device logged `gate_status_complete=True`,
`gate_status gate=E status=partial`, `gate_status gate=G status=metric_gated`,
and `gate_status gate=H status=ready`. The steering line was explicit:
`execution_priority next_gate=E
next_action=observe_strength_signal_without_counting_and_validate_hr_reference
next_local_gate=none
next_local_action=no_local_code_unblocker_collect_external_reference_or_real_workout`.
This means the fastest honest path is not more START/history opcode churn. Gate
B still needs an external RR/IBI RMSSD comparison, Gate D still needs an
independent HR reference, Gate E still needs a real sustained-HR workout or HR
reference validation, and Gate F needs more real history or HRV reference
validation.

**Gate execution update 2026-06-15 reference handoff wrapper:** the remaining
external-reference path is now packaged as `./reference_handoff.sh <run-label>`.
It runs the cabled physical-iPhone launcher with RR package export, HR package
export, HealthKit independent-HR audit, fast gate status, reference-package
pull, and `sessions.json` pull into one evidence directory. This is an
acceleration tool, not a metric shortcut: the pulled WHOOP-side packages still
require independent RR/IBI and HR comparison before Gates B, D, E, G, or C/F
can advance. Physical iPhone evidence in
`docs/evidence/reference-handoff/20260615-reference-handoff-summary-fix-device-verify/`
verified the full wrapper path: Atria built/launched on the cabled iPhone,
exported `rr_reference_package status=ok` (`raw=368`, `kept=361`,
`conf=98`, `max_rr_gap_s=1.8`, `rmssd=32.7`), exported
`hr_reference_package status=ok` (`samples=11236`, `coverage_percent=100`),
completed `healthkit_reference_audit status=ok` with
`independent_hr_samples=0`, pulled both RR/HR CSV+manifest pairs, and pulled
valid `sessions.json`. The summary remains fail-closed: `reference_validated=0`
and `gate_status gate=B` remains `reference_pending`.

**Gate execution update 2026-06-15 current reference handoff:** the current
197-session store was re-exported on the physical iPhone in
`docs/evidence/reference-handoff/20260615T-current-reference-handoff-device-verify/`.
The pulled RR handoff is
`atria-rr-reference-20260614T224410Z-gate-b-300s-live-rr.csv` plus its schema-2
manifest: `raw=368`, `kept=361`, `confidencePercent=98`,
`maxRRGapSeconds=1.76`, `rmssdMs=32.69`, `readyForExternalReference=true`,
`referenceValidated=false`, and `gateBPassed=false`. The pulled HR handoff is
`atria-hr-reference-20260614T224410Z-gate-e-overnight-checkpoint-run.csv` plus
its manifest: `hrSamples=11236`, `durationSeconds=10801`,
`observedSeconds=10800.704`, `streamCoveragePercent=100`,
`readyForExternalReference=true`, `referenceValidated=false`, and
`gateDPassed=false`. The same run logged `healthkit_reference_audit status=ok`
with `independent_hr_samples=0`, proving HealthKit still has no independent
non-Atria HR reference. This phase does not pass Gate B/D; it refreshes the
exact artifacts needed for an external RR/IBI and HR comparison.

**Gate execution update 2026-06-15 reference validation wrapper:**
`./reference_validate.sh <run-label> --rr external-rr.csv --hr external-hr.csv`
now packages the inverse path: push independent RR/IBI and HR CSVs into the
app container, run Atria's on-device RR and HR validators, audit HealthKit
independent HR, log fast gate status, and pull `sessions.json`. Running it
without `--rr` or `--hr` is a fail-closed smoke for the current missing-reference
state; it must log missing reference rows and leave Gate B/D closed. Physical
iPhone evidence in
`docs/evidence/reference-validate/20260615-reference-validate-missing-device-verify/`
verified that fail-closed path: `hr_reference_validation status=missing`,
`rr_reference_validation status=missing`, `healthkit_reference_audit status=ok`
with `independent_hr_samples=0`, `gate_status gate=B status=reference_pending`,
`gate_status gate=D status=partial`, and valid pulled `sessions.json`.

**Gate execution update 2026-06-15 self-reference rejection:** physical iPhone
evidence in
`docs/evidence/reference-validate/20260615-reference-validate-self-reject-device-verify/`
pushed Atria's own exported RR and HR CSVs back into the app container as
deliberately invalid "references." The on-device validators rejected both:
`rr_reference_validation status=fail reason=same_content_not_external_reference`
and `hr_reference_validation status=fail reason=same_content_not_external_reference`,
with `gate_b_pass=0`, `gate_d_pass=0`, and `reference_validated=0`. Follow-up
evidence in
`docs/evidence/reference-validate/20260615-reference-validate-clear-after-self-reject/`
ran `--clear`, logged `reference_inputs_clear status=ok removed=2`, then returned
both validators to `status=missing`. This closes the easiest fake-reference
path without advancing Gate B or D.

**Gate execution update 2026-06-15 parsed reference result bits:**
`reference_validate.sh` now appends machine-readable result fields to every
summary: `ATRIA_REFERENCE_RR_STATUS`,
`ATRIA_REFERENCE_RR_GATE_B_PASS`, `ATRIA_REFERENCE_HR_STATUS`, and
`ATRIA_REFERENCE_HR_GATE_D_PASS`. Optional `--require-rr-pass` and
`--require-hr-pass` flags make final validation runs exit nonzero unless the
corresponding on-device gate pass bit is `1`, so command success cannot be
mistaken for a clinical pass. Physical iPhone evidence:
`docs/evidence/reference-validate/20260615-reference-validate-result-bits-device-verify/`
logged `rr_reference_validation status=missing ... gate_b_pass=0`,
`hr_reference_validation status=missing ... gate_d_pass=0`,
`ATRIA_REFERENCE_RR_GATE_B_PASS=0`, `ATRIA_REFERENCE_HR_GATE_D_PASS=0`, valid
`sessions.json`, and `HARNESS_CAPTURE_TIMEOUT ... action=stop_devicectl_console`
with no remaining validator process. Gate B and Gate D remain reference-gated.

**Gate execution update 2026-06-15 current reference handoff refresh:** the
latest post-sleep-audit store was re-exported on the physical iPhone in
`docs/evidence/reference-handoff/20260615T-current-reference-handoff-202-sessions-device-verify/`.
The RR package is
`atria-rr-reference-20260614T235628Z-gate-b-300s-live-rr.csv` with schema-2
manifest values `raw=368`, `kept=361`, `confidencePercent=98`,
`maxRRGapSeconds=1.7638`, `rmssdMs=32.6866`, `sdnnMs=50.4951`,
`pnn50Percent=13.3333`, `lnRmssd=3.4870`,
`readyForExternalReference=true`, and `gateBPassed=false`. The HR package is
`atria-hr-reference-20260614T235627Z-gate-e-overnight-checkpoint-run.csv` with
`hrSamples=11236`, `durationSeconds=10801`,
`observedSeconds=10800.704`, `streamCoveragePercent=100`, `avgHR=58.1072`,
`peakHR=85`, `restingHR=47`, `readyForExternalReference=true`, and
`gateDPassed=false`. HealthKit independent-HR audit again reported
`independent_hr_samples=0`, and the device emitted
`execution_priority next_gate=B ... next_local_action=no_local_code_unblocker_collect_external_reference_or_real_workout`.
This keeps the exact current external-reference artifacts ready while preserving
the honest blocker: no B/D/C/G metric pass until independent RR/IBI and HR
references validate on the physical iPhone.

**Gate execution update 2026-06-15 handoff summary bits:** `reference_handoff.sh`
now appends parsed manifest fields to `reference-handoff-summary.txt`, including
`ATRIA_HANDOFF_RR_READY_FOR_EXTERNAL_REFERENCE`,
`ATRIA_HANDOFF_RR_GATE_B_PASSED`,
`ATRIA_HANDOFF_HR_READY_FOR_EXTERNAL_REFERENCE`, and
`ATRIA_HANDOFF_HR_GATE_D_PASSED`. This makes handoff runs easier to consume by
future sessions while preserving the metric contract: ready-for-reference can be
`1`, but Gate B/D pass bits stay `0` until independent RR/IBI and HR CSVs
validate on the physical iPhone.
Device verification:
`docs/evidence/reference-handoff/20260615T-reference-handoff-summary-bits-device-verify/`
built and launched on the cabled iPhone, produced
`ATRIA_HANDOFF_RR_READY_FOR_EXTERNAL_REFERENCE=1`,
`ATRIA_HANDOFF_RR_GATE_B_PASSED=0`,
`ATRIA_HANDOFF_HR_READY_FOR_EXTERNAL_REFERENCE=1`, and
`ATRIA_HANDOFF_HR_GATE_D_PASSED=0`.

**Gate execution update 2026-06-15 reference next-steps handoff:** `reference_handoff.sh`
now relaunches Atria with `--leave-running` after a successful handoff and writes
`REFERENCE_NEXT_STEPS.md` into the evidence folder. The next-steps artifact is
generated from the actual pulled RR/HR manifests and contains the exact Atria
CSV paths, session labels, RMSSD/coverage values, accepted external CSV header
shapes, and the `reference_validate.sh --require-rr-pass` /
`--require-hr-pass` commands to run after an independent recording is available.
The wrapper also has a fail-closed fallback: if `devicectl --console` or a
handoff assertion fails before the normal `--leave-running` path, it attempts a
safe no-console Long wear relaunch before exiting nonzero. Physical iPhone
evidence:
`docs/evidence/reference-handoff/20260615T-reference-handoff-next-steps-device-verify-success/`
built, installed, launched on the cabled iPhone, emitted Gate Status, exported
and pulled the RR and HR reference packages, pulled `sessions.json`, wrote
`REFERENCE_NEXT_STEPS.md`, and relaunched Atria in low-radio Long wear mode.
Follow-up process inspection showed Atria still running. Gate B and Gate D
remain blocked exactly as before: `referenceValidated=false`,
`gateBPassed=false`, `gateDPassed=false`, and HealthKit still has
`independent_hr_samples=0`.

**Gate execution update 2026-06-15 Atria launcher aliases:** physical-device
launchers now prefer Atria-named environment variables for operator control:
`ATRIA_DEVICE_ID`, `ATRIA_LIVE_DEBUG_SECONDS`, `ATRIA_LIVE_DEBUG_LOG`,
`ATRIA_REFERENCE_HANDOFF_SECONDS`, and `ATRIA_REFERENCE_VALIDATE_SECONDS`.
Legacy `WHOOP_*` variables remain accepted so existing evidence replay and older
scripts do not break. This is execution hygiene only; it does not change metric
readiness or the Gate B/D external-reference blockers.
Physical iPhone evidence:
`docs/evidence/gate-status/20260615T-atria-launcher-aliases-device-verify/`
used `ATRIA_DEVICE_ID`, `ATRIA_LIVE_DEBUG_SECONDS`, and
`ATRIA_LIVE_DEBUG_LOG`, built successfully, launched Atria, emitted Gate Status,
completed low-radio verification, and pulled `sessions.json`.

**Gate E/G durability update 2026-06-15 active-journal close provenance:**
`ActiveSessionJournal.evidence()` now reports `active_journal_last_close_*`
fields in addition to current active-journal presence. When Atria safely closes
an active journal into the session store during disconnect autosave, checkpoint,
or long-gap rollover, the next Gate Status row can distinguish
`active_journal_present=0` because there is no journal from
`active_journal_present=0` because the prior journal was safely persisted. This
supports the unattended logging/reconnect requirement without promoting sleep,
workout, strain, or HRV metrics.
Physical iPhone evidence:
`docs/evidence/gate-status/20260615T-active-journal-close-provenance-device-verify/`
confirmed the fields are emitted when no close has happened
(`active_journal_last_close_status=none`), and
`docs/evidence/gate-status/20260615T-active-journal-close-provenance-flush-device-verify/`
confirmed Gate Status preserves a prior closed-journal record
(`active_journal_last_close_status=cleared`,
`active_journal_last_close_reason=long_gap_rollover`) while a new active journal
continues saving. This is a durability/diagnostic checkpoint only; Gate B stays
external-reference-pending and Gate E/G stay blocked by their existing metric
confidence requirements.

**Gate B/D reference-validation update 2026-06-15 single-candidate CSV auto-selection:**
The on-device reference validators now prefer the exact contract files
`Documents/atria-reference/rr-reference.csv` and `hr-reference.csv`, but if the
preferred file is absent they can auto-select exactly one plausible local CSV
candidate in the same folder. Multiple plausible candidates remain fail-closed
as ambiguous. Accepted candidate names must still be CSVs whose basename looks
like the reference type (`rr`, `ibi`, `interval`, or `nn` for RR; `hr`, `heart`,
or `bpm` for HR), and all clinical thresholds are unchanged: Gate B still needs
a ready 300-second external RR/IBI comparison within 5 ms RMSSD; Gate D still
needs independent HR pairs within 2 bpm. The harness gained
`--push-rr-reference-as` and `--push-hr-reference-as` only to verify this
resolver path on the device.
Physical iPhone evidence:
`docs/evidence/reference-validate/20260615T-reference-auto-select-clear-device-verify/`
confirmed the missing-reference state reports `candidate_count=0`, and
`docs/evidence/reference-validate/20260615T-reference-auto-select-candidate-device-verify/`
confirmed `single-rr-candidate.csv` and `single-hr-candidate.csv` were
auto-selected. Both validations correctly stayed fail-closed because the proof
CSVs were intentionally too short (`gate_b_pass=0`, `gate_d_pass=0`,
`reference_validated=0`). This removes reference-file naming friction without
weakening the no-fake-metrics contract.

**Phase E update 2026-06-15 Gate E sleep-confidence alignment:**
`SessionStore` gate-status logging now matches the dashboard gate contract:
Gate E requires validated/ready sleep evidence plus a ready sustained workout.
Low-confidence HR-only sleep days are logged as `sleep_ready=0` with
`sleep_blocker=sleep_low_confidence`, so a future ready workout cannot make
`gate_status gate=E` report `ready` while sleep still lacks validated motion or
the documented confidence fallback. This is an honesty hardening, not a Gate E
pass. Physical iPhone evidence:
`docs/evidence/gate-e/20260615T-gate-e-sleep-confidence-alignment-device-verify/`
logged `gate_status gate=E status=partial ... sleep_ready=0
... sleep_blocker=sleep_low_confidence`, kept the strength candidate
`diagnostic_only`, and updated `execution_priority` to include
`E:validated_sleep_confidence,E:real_sustained_workout`.

**Phase E update 2026-06-15 sleep validation confidence gate:**
Sleep readiness now uses one shared `SleepEvidenceStatus` path for dashboard,
gate-status, and `--verify-sleep`. Aggregate and single-session sleep
validation only report `status=ready` when the sleep candidate has validated
low-motion evidence (`motion_validated=1` and non-low confidence). HR-only
overnight candidates remain `status=learning` with
`reason=sleep_low_confidence_motion_unvalidated`, preserving the local evidence
without converting it into a Gate E pass.

**Gate execution update 2026-06-15 side-effect completion stop:**
`live_device_debug.sh` now tracks completion of requested in-app side effects
such as sleep validation, HealthKit export/audit, reference package export,
reference validation, and backup verification. A `--log-gate-status` run with
post-run artifact pulls can now detach from `devicectl --console` as soon as the
gate-status line and requested WHOOPDBG side-effect evidence are present, then
perform the file pulls. This is a speed/reliability improvement only: it does
not relax any metric gate or promote incomplete sleep, HRV, HR, or workout data.

**Gate G update 2026-06-15 notification delivery completion:** Diagnostic
notification verification is now a first-class harness side effect. When
`--test-notification` is combined with `--log-gate-status`, the launcher waits
for both `notification_schedule status=...` and
`notification_delivered kind=diagnostic` before detaching from the physical
iPhone console. Production metric notifications remain confidence-gated; this
only hardens the evidence path for Gate G notification delivery.

**Gate execution checkpoint 2026-06-15 current blockers:** a fresh cabled
iPhone snapshot in
`docs/evidence/gate-status/20260615T022952-current-gate-snapshot/` pulled valid
`sessions.json`, emitted all gate-status lines, and reported no harness error or
capture timeout. The current state is explicit: Gate B remains
`reference_pending` with `validated_hrv_sessions=0`; Gate C remains
`learning` with validated HRV baseline `0/7`; Gate D remains `partial` because
the independent HR reference is missing; Gate E remains `partial` because sleep
is low-confidence and the best workout-like window has only `elevated_s=3`
against the `480` second sustained-bout requirement; Gate F remains `learning`;
Gate G remains `metric_gated`; Gate H remains `ready` for protocol exit but
historical metrics stay fail-closed. The on-device priority line is
`next_local_gate=none` and
`next_local_action=no_local_code_unblocker_collect_external_reference_or_real_workout`,
so the next honest checkpoint is real-world/reference evidence, not another
blind BLE START retry, speculative history selector, or fabricated metric.

**Gate G/E low-radio evidence hardening 2026-06-15:** long-wear and
standard-HR-only operation now emits explicit radio evidence into WHOOPDBG gate
status: `radio_mode`, `radio_standard_hr_only`, `radio_custom_notify_skipped`,
`radio_custom_notify_enabled`, `radio_tx_skipped`, and
`radio_realtime_start_skipped`. This is a platform-polish and long-wear
reliability improvement after the gym/AirPods interference report. It does not
advance HRV, strain, sleep, or workout metrics by itself; it makes the chosen
low-radio collection mode auditable on the physical iPhone. The launcher also
waits for a post-connection `radio_low_traffic status=ready` line during
standard-HR-only gate snapshots, so pre-connection gate rows cannot be mistaken
for evidence that custom WHOOP traffic was actually suppressed. Full custom
WHOOP protocol traffic stays reserved for deliberate Gate B/H protocol runs.

**Gate E update 2026-06-15 always-on HR proof plan:** when workout readiness is
zero, Atria now always emits `WHOOPDBG hr_profile_validation_plan`, not only the
earlier profile-specific subset. The line carries the exact `next_action`,
`next_proof`, and `required_proof` so a real-world capture cannot end with only
a generic `learning` state. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-hr-profile-plan-always-device-verify/` built,
installed, launched, pulled valid `sessions.json`, logged
`gate_status gate=E status=partial`, and emitted
`hr_profile_validation_plan ... always_emit_when_workout_ready_0=1`. The current
truth stayed fail-closed: the best stitched workout-like span had 85% stream
coverage but only 3 seconds above HRR50 versus the required 1200 seconds and a
3-second longest bout versus the required 480 seconds. The plan therefore
requires an independent HR reference or profile update before counting that
signal as a workout; no strain/workout credit was granted.

**Gate B update 2026-06-15 saved-RR status correction:** fast gate status no
longer reports `saved_rr_ready=0` just because RR replay was skipped. It now runs
the same saved-RR replay used by the RR reference-package exporter and includes
the best 300-second window in `gate_status gate=B`. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-gate-b-status-rr-replay-device-verify/` built,
installed, launched, pulled valid `sessions.json`, and logged
`gate_status_progress stage=rr_replay_done ... ready=1 ... raw=368 kept=361
conf=98 max_gap_s=1.8 reason=ready`. The resulting Gate B row now says
`saved_rr_ready=1`, `saved_rr_best_rmssd=32.7`, and
`rr_replay=computed_status`; the exported RR package reports the same window.
This does not pass Gate B: `status=reference_pending`,
`external_rr_reference_required=1`, and `reference_validated=0` remain true until
an independent RR/IBI recording validates RMSSD within ±5 ms.

**Gate B update 2026-06-15 execution priority alignment:** because Gate B now
has a clean saved RR window, `execution_priority` now honors the gate order and
reports `next_gate=B` with
`next_action=provide_external_rr_reference_for_ready_rr_window` before later Gate
E workout blockers. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-gate-b-priority-ready-rr-device-verify/` built,
installed, launched, pulled valid `sessions.json`, logged
`gate_status gate=B ... saved_rr_ready=1 ... saved_rr_best_rmssd=32.7`, and then
logged the new `execution_priority` line. `next_local_gate=none` remains correct:
there is no local code unblocker for the remaining Gate B exit without an
independent RR/IBI reference.

**Gate B update 2026-06-15 RR reference manifest contract:** RR reference
package manifests now use schema 2 and carry the validation contract alongside
the exported 300-second window: expected external path
`Documents/atria-reference/rr-reference.csv`, accepted RR/time column aliases,
300-second alignment, `300-2000 ms` range correction, `|delta RR| <= 20%`,
`>=240` corrected beats, `>=75%` confidence, no `>3s` RR gap, `+/-5 ms` RMSSD
tolerance, and explicit independent-reference/self-comparison rules. This does
not pass Gate B; it prevents the remaining external-reference step from being
misread as an Atria-vs-Atria parser check. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-rr-reference-manifest-contract-device-verify/`
built, installed, launched, pulled valid `sessions.json`, logged
`rr_reference_package ... reference_path=Documents/atria-reference/rr-reference.csv
tolerance_ms=5 self_compare_rejected=1 schema=2`, and pulled the schema 2
manifest.

**Current gate audit 2026-06-15 after RR manifest contract:** physical iPhone
evidence in
`docs/evidence/gate-status/20260615T-post-rr-manifest-contract-audit/` confirms
the post-checkpoint state. Gate B is `reference_pending` with `saved_rr_ready=1`
and `reference_validated=0`; `execution_priority` still says
`next_gate=B next_action=provide_external_rr_reference_for_ready_rr_window
next_local_gate=none`. Gate H remains protocol-ready, while Gate C/G HRV,
Gate D, and Gate E remain gated by independent reference or real-world
validation evidence.

**Gate B tooling update 2026-06-15 RR reference reducer + early exit:** the Mac
gate reducer now parses `WHOOPDBG rr_reference_package` and
`WHOOPDBG rr_reference_validation` rows directly, including focused
reference-only logs and broad local-status logs that previously hid the precise
Gate B package state. The launcher also exits once requested reference
package/validation side effects have completed, so these checks no longer wait
for unrelated long-wear timers. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-rr-reference-early-exit-device-verify/` built,
installed, launched, exported, validated, and pulled the current WHOOP-side RR
package. The reducer reports Gate B as `reference_pending` with the ready
WHOOP window (`raw=368`, `kept=361`, `conf=98`, `max_rr_gap_s=1.8`,
`rmssd=32.7`) and the next action
`provide_independent_rr_ibi_recording`. The on-device validator correctly failed
the existing reference file with `reason=reference_window`, `reference_raw=5`,
`reference_ready=0`, `rmssd_delta_ms=18.3`, `gate_b_pass=0`, and
`reference_validated=0`. This is not a Gate B pass; it proves the remaining
blocker is the external RR/IBI recording, not local package generation or parser
wiring.

**Gate E sleep blocker precision update 2026-06-15:** sleep remains fail-closed
unless a low-motion source is validated, but the blocker is now specific instead
of the generic `sleep_low_confidence`. Atria reports whether the missing proof is
historical gravity absence, timestamp non-overlap, insufficient overlap
coverage, insufficient validated gravity rows, high motion variance, or
observe-only motion hints. This should make the next sleep validation action
clear without promoting HR-only sleep to ready. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-sleep-blocker-precision-device-verify-final/`
built, installed, launched, pulled valid `sessions.json`, and logged both
`gate_status gate=E ... sleep_blocker=sleep_motion_unvalidated_no_historical_overlap`
and `sleep_validation status=learning
reason=sleep_motion_unvalidated_no_historical_overlap`.

**Gate execution update 2026-06-15 sleep-priority precision:** `execution_priority`
now reuses Gate E's precise sleep blocker in `real_world_needed` instead of
collapsing all unready sleep evidence to `E:validated_sleep_confidence`. This
keeps the top-level action map aligned with the fail-closed Gate E diagnostic
without changing sleep or workout readiness criteria. Physical iPhone evidence
in `docs/evidence/gate-e/20260615T-sleep-priority-precision-device-verify/`
built, installed, launched, pulled valid `sessions.json`, and logged
`real_world_needed=E:sleep_motion_unvalidated_no_historical_overlap,E:real_sustained_workout,...`.

**Gate E tooling update 2026-06-15 analyzer blocker alignment:** the
`tools/analyze_gate_status.py` Gate E row now reports sleep and workout blockers
together instead of hiding a precise sleep blocker behind the workout near-miss.
This keeps local audits aligned with the device logs: sleep remains blocked by
`sleep_motion_unvalidated_no_historical_overlap`, while workout remains blocked
by the real sustained-HR near-miss (`insufficient_elevated_time` plus short
elevated/bout duration). This does not pass Gate E or relax any threshold; it
prevents future execution from chasing the wrong single blocker. Physical iPhone
evidence in
`docs/evidence/gate-e/20260615T-gate-status-analyzer-blocker-alignment-device-verify/`
built, installed, launched, pulled valid `sessions.json`, logged
`gate_status gate=E ... sleep_blocker=sleep_motion_unvalidated_no_historical_overlap`,
and saved analyzer output with both the sleep blocker and workout near-miss.

**Gate E sleep update 2026-06-15 stale-history blocker:** historical gravity
motion validation now distinguishes nearby timestamp non-overlap from stale
stored history. If the downloaded gravity range is more than 24 hours away from
the sleep window and older than the candidate, Atria reports
`historical_motion_reason=historical_archive_stale` and
`sleep_blocker=sleep_motion_unvalidated_historical_stale`. This keeps sleep
fail-closed while pointing the next real unblocker at current-history selection
or validated current IMU/current motion, instead of wasting effort on clock
drift for an old March archive. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-sleep-stale-history-blocker-device-verify/`
built, installed, launched, pulled valid `sessions.json`, logged
`gate_status gate=E ... sleep_blocker=sleep_motion_unvalidated_historical_stale`,
and logged `sleep_validation ... historical_motion_reason=historical_archive_stale`.

**Gate G tooling update 2026-06-15 HealthKit readback guard:** after the latest
Health permission change, a cabled iPhone recheck in
`docs/evidence/gate-g/20260615T-healthkit-permission-current-verify/` proved
HealthKit authorization is cached and Atria can save another incremental HR
delta (`healthkit_export status=saved ... hr_samples=551`). It also exposed a
harness honesty gap: the run could finish before the asynchronous
`healthkit_export_verify` readback appeared. The device harness now requires a
`WHOOPDBG healthkit_export_verify` row for every `--healthkit-export` phase, so
future Gate G evidence must prove both HealthKit save and Apple Health readback;
the post-patch cabled-iPhone rerun stayed alive through
`healthkit_export_verify status=ok reason=up_to_date readback_covers_delta=1
data_appears=1`.
Gate G remains `metric_gated`, not complete, until Gate B HRV and Gate E
workout/sleep produce exportable validated metrics.

**Gate status tooling update 2026-06-15 Gate G metric-gated guidance:** the
Mac log reducer now treats `gate_status gate=G status=metric_gated` as
platform-verified rather than telling the next run to redo HealthKit/widget/
backup verification. Analyzer output now says Gate G is waiting on
`healthkit_hrv_reference_pending+healthkit_workout_learning`, keeping execution
focused on Gates B/E instead of a completed platform loop.

**Gate G tooling update 2026-06-15 widget snapshot guard:** the physical-device
harness now treats `--log-widget-snapshot` as a strict completion target:
future widget evidence must emit `WHOOPDBG widget_snapshot status=...` or the
run fails with `HARNESS_ERROR=widget_snapshot_incomplete`. Physical iPhone
evidence in
`docs/evidence/gate-g/20260615T-widget-harness-completion-device-verify/`
built, installed, and launched Atria, then logged `widget_snapshot_complete=True`
with `storage=app_group_userdefaults`, `app_group=1`, `widget_target=1`, and
`complication_target=1`. `tools/analyze_gate_status.py` now synthesizes a
focused Gate G row from widget-only evidence and reports `metric_gated` on
`healthkit_hrv_reference_pending+healthkit_workout_learning`, so this hardens
the verifier without pretending HRV/workout exports are done.

**Gate H/E recheck 2026-06-15 NOOP backfill still stale:** a targeted
NOOP-style backfill recheck on the cabled iPhone in
`docs/evidence/gate-h/20260615T-current-history-noop-backfill-recheck/` pulled
the same persisted historical archive shape (`728` codec-clean rows) and still
reported `current_session_usable_rows=0`, `metric_usable_rows=0`, and
`gate_status gate=E ... sleep_blocker=sleep_motion_unvalidated_historical_stale`.
This rules out repeating plain `--history-noop-backfill` as a current sleep or
workout unblocker. The next local path must be a different current-history
selector or validated live IMU/current-motion evidence; otherwise sleep stays
learning and the old archive remains diagnostic/protocol evidence only.

**Gate H/E update 2026-06-15 live IMU counter proof:** Atria now persists
protocol packet counters and exposes them in `local_status` plus Gate H status
so live-current-motion experiments can be ruled in or out without relying on
verbose BLE logs. The cabled iPhone full-protocol run in
`docs/evidence/gate-h/20260615T-protocol-imu-counter-device-verify/` reset the
counters, collected for 100 seconds, and then logged `protocol_packets=5`,
`protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
`protocol_event_frames=3`, and `protocol_last_type=30`. This proves the
current subscription plus realtime START path is receiving event/protocol
traffic but not live `0x33` IMU frames. Do not promote current-motion sleep or
workout detection from this path yet; the remaining local unblocker is a new
IMU/current-history trigger or selector with nonzero `protocol_imu_frames`.

**Gate H/E update 2026-06-15 passive live-motion recheck:** the cabled iPhone
run in
`docs/evidence/gate-h/20260615T-live-motion-passive-recheck-device-verify/`
rebuilt Atria, launched full-protocol mode with protocol counters reset, held a
170-second live diagnostic window, then launched a post-window Gate Status read.
The useful window saw real custom protocol traffic (`protocol_packets=2`,
`protocol_event_frames=1`, `protocol_unknown_frames=1`) but no motion-bearing
source: `protocol_imu_frames=0`, `protocol_diagnostic_frames=0`,
`sleep_motion_hint_count=0`, no `imu_candidate`, and no `0x33` frame-type
counters. This is a passive recheck, not an active wrist-motion proof; it rules
out passive foreground full-protocol subscription as a current sleep-motion
source and keeps Gate E blocked on a true current-history selector, validated
live-IMU trigger, or official-app/sniffer evidence.

**Gate E update 2026-06-15 long-wear watchdog evidence:** after the NOOP/whoof
cross-check, the actionable local path is standard `2A37` collection hardening,
not more proprietary START/history churn. Atria now persists long-wear watchdog
recovery counters (`watchdog_no_data_recoveries`,
`watchdog_hr_continuity_recoveries`, `watchdog_accepted_hr_recoveries`) and
prints them in `local_status` and Gate E evidence. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-watchdog-recovery-evidence-device-verify/`
built successfully, then forced the no-data watchdog on the cabled iPhone:
`no_data_watchdog status=forced gap_s=24.4 checkpoint=saved
action=fresh_scan_reconnect`. The following in-app diagnostic reported
`watchdog_no_data_recoveries=1`, `watchdog_last_source=no_data`,
`watchdog_last_action=fresh_scan_reconnect`, and
`checkpoint_last_status=saved_no_data_watchdog`. This is recovery observability
and durability hardening, not a Gate E pass: replay still reports `ready=0`,
best workout windows remain stream/HR-band limited, and sleep remains blocked
by `sleep_motion_unvalidated_historical_stale`.

**Gate status tooling update 2026-06-15 bounded fast RR replay:** the current
store has grown enough that fast Gate Status could be killed while waiting for
an exhaustive saved-RR replay, leaving `gate_status_incomplete` even though the
local/Gate E evidence was present. Fast status now bounds saved-RR replay to the
12 RR-richest sessions and labels the B evidence `rr_replay=computed_bounded_fast`;
deep status keeps the exhaustive path. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-fast-status-bounded-rr-device-verify/`
rebuilt, installed, launched, pulled valid `sessions.json`, and emitted
`execution_priority` cleanly. The bounded replay still found the known ready RR
window (`saved_rr_ready=1`, `saved_rr_best_label=gate-b-300s-live-rr`,
`raw=368`, `kept=361`, `conf=98`, `max_gap_s=1.8`), so this is a speed and
reliability improvement without relaxing Gate B's external-reference blocker.

**Gate E update 2026-06-15 HR-only sleep fallback diagnostics:** Atria now
reports HR-only sleep fallback evidence separately from sleep readiness. This
keeps interrupted overnight low-HR aggregates visible while preserving the Gate
E contract that sleep is not `ready` until current motion/IMU or validated
historical motion overlaps the sleep window. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-sleep-fallback-diagnostics-device-verify/`
built, installed, launched, ran Gate Status plus sleep validation, and pulled
`sessions.json`. The cabled device logged
`gate_status gate=E status=partial ... sleep_ready=0 ...
sleep_blocker=sleep_motion_unvalidated_historical_stale ...
sleep_fallback_available=1 ... sleep_fallback_source=hr_only_fragmented_sleep
... sleep_fallback_duration_s=10545 ... sleep_fallback_chunks=2 ...
sleep_fallback_diagnostic_only=1`, and `sleep_validation status=learning`
with the same fallback markers. `tools/analyze_gate_status.py` now surfaces this
fallback as diagnostic-only evidence instead of hiding it behind the motion
blocker. This does not pass Gate E: stale March historical gravity remains
diagnostic-only, sleep motion is still unvalidated for the current night, and
the workout side is still a near-miss rather than a counted workout.

**Gate H/E update 2026-06-15 active-motion IMU preset:** Atria now has a
first-class `live_device_debug.sh --active-motion-imu-check` physical-device
preset for the remaining local motion question. The preset forces full-protocol
mode, resets protocol counters, arms a documented
`30s still -> 30s wrist rotations/taps -> 30s still -> 30s walking arm swing`
script, and uses the new `--log-gate-status-after N` launch argument so Gate
Status is emitted after the protocol window instead of before it. The first
physical iPhone smoke in
`docs/evidence/gate-h/20260615T-active-motion-imu-preset-device-verify/`
proved the old immediate status ordering was too early (`protocol_packets=0`).
The delayed rerun in
`docs/evidence/gate-h/20260615T-active-motion-imu-delayed-status-device-verify/`
built cleanly, installed/launched on the cabled iPhone, armed the preset, logged
`gate_status schedule delay_s=60.0`, pulled sessions, and produced a complete
post-window status. Result: realtime/RR and custom protocol traffic were alive
(`realtime_rr_fraction=0.956`, `protocol_packets=2`,
`protocol_event_frames=1`, `protocol_unknown_frames=1`) but no current
motion-bearing source appeared (`protocol_imu_frames=0`,
`protocol_diagnostic_frames=0`, `sleep_motion_hint_count=0`). This checkpoint
does not pass Gate E or validate live IMU; it makes the active-motion test
repeatable and keeps sleep/workout motion in `learning` until a deliberate
active script yields nonzero IMU/current-motion evidence or an external
official-app/sniffer capture identifies the missing trigger.

**Gate status tooling update 2026-06-15 bounded deep evidence:** a fresh
cabled-iPhone audit exposed a verifier failure, not a new metric blocker:
combined deep status on the 197-session store could be killed before
`execution_priority`, leaving `HARNESS_ERROR=gate_status_deep_incomplete`.
Atria now labels large-store deep status as bounded
(`workout_replay_scope=bounded_large_store`, `workout_replay_limit=80`), emits
the normal A-H rows first, and skips only the expensive deep detail dump with
`gate_status_deep_detail status=skipped ... diagnostic_only=1`. The launcher
also resets its deadline after `WHOOPDBG gate_status_start` so late-starting
deep status gets a fresh completion window. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-deep-status-bounded-deadline-device-verify/`
built, installed, launched, verified backup, emitted
`HARNESS_GATE_STATUS_DEADLINE_RESET seconds=240`, completed both
`gate_status_complete=True` and `gate_status_deep_complete=True`, pulled
`sessions.json`, and produced analyzer output with the same honest state:
Gate B `reference_pending`, Gate D `partial`, Gate E `partial`, Gate G
`metric_gated`, Gate H `ready`, and
`next_local_gate=none`. This phase does not pass any metric gate; it removes a
false verifier failure so future physical-device checkpoints can be trusted.

**Gate G update 2026-06-15 battery evidence provenance:** Atria now persists the
latest valid standard Battery Level (`2A19`) read with timestamp and source,
uses live `2A19` first for battery notifications, falls back only to a fresh
persisted `2A19` cache, and labels stale or missing battery evidence as
`learning`. Gate Status now includes `battery_level`, `battery_source`,
`battery_age_s`, and `battery_usable`, so platform checks cannot mistake an
unknown battery level for a real notification decision. Physical iPhone evidence
in
`docs/evidence/gate-g/20260615T-battery-evidence-notification-device-verify/`
built cleanly, launched Atria, read and persisted `battery level=49 source=2A19`,
and logged `notification_battery_decision level=49 source=live_2A19 age_s=0
usable=1 threshold=20` followed by
`notification_skip kind=battery reason=battery_49_not_low_source_live_2A19`.
The cached launch path was verified in
`docs/evidence/gate-g/20260615T-battery-evidence-gate-status-cached-device-verify/`:
Gate Status reported `battery_level=49`, `battery_source=live_2A19`,
`battery_age_s=41`, and `battery_usable=1`, then refreshed from live `2A19`.
This improves Gate G notification honesty and observability; it does not pass
the metric-gated HealthKit HRV/workout exits.

**Gate E tooling update 2026-06-15 active journal pull:** the generic
`live_device_debug.sh --pull-sessions DIR` path now pulls the current active
Long Wear journal as `atria-active-session.json` beside `sessions.json`, with a
legacy `whoop-active-session.json` fallback. `gate_e_workout_audit.sh` now uses
the same current filename before running `tools/analyze_workout_store.py
--active-journal`, so post-workout audits no longer miss the still-running
segment just because the app renamed its local journal during the Atria cleanup.
Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-active-journal-pull-current-name-device-verify/`
first proved the explicit missing-state path (`WHOOPDBG_ACTIVE_JOURNAL_PULL_STATUS=missing`)
when no journal existed. The targeted verification in
`docs/evidence/gate-e/20260615T-active-journal-pull-flushed-device-verify/`
built cleanly, launched Atria, forced journal saves (`samples=22`, `rr_values=23`),
pulled `WHOOPDBG_ACTIVE_JOURNAL_PULL_SOURCE=Documents/atria-active-session.json`,
and produced workout-store analysis with `active_journal=1`. Gate E remained
partial (`workout_days=0`) because the real HR evidence still lacks sustained
HRR50 workout-band time; this phase removes an evidence blind spot without
lowering the detector.

**Gate F update 2026-06-15 trend coverage requirement accuracy:** Gate F
diagnostics now report the required covered days from the same 70% high-confidence
rule used by the trend UI instead of hard-coding `90` for the 90-day window.
`trend_window` rows log `required_coverage_days` for each window, and Gate F
status logs `trend90_required_coverage_days=63` plus
`trend90_required_coverage_percent=70`. Physical iPhone evidence in
`docs/evidence/gate-f/20260615T-trend-required-coverage-device-verify/` built
cleanly, launched Atria, and logged `required_coverage_days=5/21/63` for
7/30/90-day windows with real `coverage_days=3`. Gate F correctly remained
`learning` because coverage is below 70% and HRV/Recovery trend points are still
reference-gated.

**Gate F update 2026-06-15 trend blocker UI contract:** `TrendSummary` now
carries the required covered days and a fail-closed blocker string, so the
History trend rows and coverage chart show `covered/required` instead of only
raw covered days. Launch-driven `trend_window` logs now emit the same blocker
string used by the UI. Physical iPhone evidence in
`docs/evidence/gate-f/20260615T-trend-blocker-ui-device-verify/` built cleanly,
installed/launched Atria, pulled the local store, and logged 7/30/90-day
windows with `coverage_days=3`, `required_coverage_days=5/21/63`, and
`blockers=coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
Gate F remains `learning`; this phase prevents sparse trends from looking
complete on-screen.

**Gate F tooling update 2026-06-15 trend harness completion:** targeted
`--log-trends` runs are now first-class verifier runs. `live_device_debug.sh`
tracks `trend_summary_complete` plus all three `trend_window` rows and fails
with `HARNESS_ERROR=trend_summary_incomplete` or
`HARNESS_ERROR=trend_windows_incomplete` if the physical-device log is
incomplete. `tools/analyze_gate_status.py` also synthesizes a Gate F row from a
trend-only log instead of reporting Gate F as missing. Physical iPhone evidence
in `docs/evidence/gate-f/20260615T-trend-harness-completion-device-verify/`
built cleanly, installed/launched Atria, connected BLE, and completed with
`trend_summary_complete=True` and `trend_windows_complete=True`. Current store
truth remains fail-closed: `sessions=282`, 7-day coverage `3/5` partial,
30-day `3/21` learning, 90-day `3/63` learning, HRV/recovery trend points
reference-gated, and `anomaly_flags=none`.

**Gate G update 2026-06-15 post-permission HealthKit proof:** after Apple
Health write permission was granted, the cabled iPhone run in
`docs/evidence/gate-g/20260614T233211Z-healthkit-post-permission-device-verify/`
built, installed, launched Atria, reused cached HealthKit authorization, saved a
fresh incremental HR delta (`healthkit_export status=saved ... hr_samples=39
workouts=0 hrv_samples=0`), and read Apple Health back with
`healthkit_export_verify status=ok ... readback_covers_delta=1 ...
data_appears=1`. The same audit remained honest about references:
`healthkit_reference_audit ... independent_hr_samples=0`, so HealthKit readback
does not count as external HR validation. Atria now schedules a second Gate
Status block after launch-driven HealthKit export/audit requests so Gate G rows
can include the post-export readback state instead of a stale pre-callback
snapshot. The verifier run in
`docs/evidence/gate-g/20260614T233522Z-post-healthkit-gate-status-device-verify-2/`
proved that behavior on the physical iPhone: it logged
`launch_exports_post_healthkit_gate_status status=completed`, then emitted a
post-readback Gate G row with `healthkit_readback_status=ok` and
`metric_blockers=healthkit_hrv_reference_pending+healthkit_workout_learning`.
The device harness now waits for that post-HealthKit Gate Status marker whenever
HealthKit export/audit and Gate Status are requested together.
`tools/analyze_gate_status.py` also reports the real Gate G blocker for
`metric_gated` rows (`healthkit_hrv_reference_pending+healthkit_workout_learning`)
instead of the ambiguous `platform_verification`. Gate G remains metric-gated
until Gate B HRV and Gate E workout eligibility provide exportable HRV/workout
samples.

**Gate G update 2026-06-15 Atria widget capability key:** the embedded widget
extension now advertises accessory-family support with
`AtriaWidgetSupportsAccessoryFamilies` instead of the old project-name key, and
the app keeps a legacy fallback reader for older extension plists. Physical
iPhone evidence in
`docs/evidence/gate-g/20260615T-atria-widget-capability-key-device-verify/`
built, installed, launched, and verified the signed extension plist contains
`AtriaWidgetSupportsAccessoryFamilies => true` while `WHOOPDBG widget_readiness`
still reports `status=ready`, `app_group=1`, `widget_target=1`, and
`complication_target=1`. Gate G remains `metric_gated` because HRV/workout
exports are still blocked by the upstream reference/workout gates.

**Gate G update 2026-06-15 HealthKit readback reconciliation:** HealthKit
readback diagnostics now expose whether the full expected Atria HR sample total
is reconciled, not only whether a fresh delta appears. Physical iPhone evidence
in `docs/evidence/gate-g/20260615T-healthkit-readback-reconciliation-device-verify/`
built cleanly, installed/launched Atria, saved a fresh HealthKit HR delta
(`hr_samples=204`), and read it back (`readback_covers_delta=1`,
`data_appears=1`). The same run logged the historical gap honestly:
`expected_total_atria_hr_samples=48456`, `readback_atria_hr_samples=45793`,
`missing_total_atria_hr_samples=2663`, and
`reconciliation=legacy_backfill_pending`. Gate G remains `metric_gated` with
`healthkit_hr_backfill_pending+healthkit_hrv_reference_pending+healthkit_workout_learning`
instead of implying the HealthKit path is fully reconciled.

**Gate G update 2026-06-15 HealthKit overfill honesty:** The attempted HR
backfill exposed a second, more important truth condition: this Apple Health
store now contains duplicate/overfilled Atria HR rows from the earlier broad
repair attempt. `docs/evidence/gate-g/20260615T-healthkit-overfill-honesty-device-verify/`
rebuilt, installed, and launched Atria on the physical iPhone, saved a fresh
incremental delta (`hr_samples=9`), and read Apple Health back. The readback
covered the delta but was not cleanly reconciled:
`expected_total_atria_hr_samples=48486`, `readback_atria_hr_samples=89177`,
`overfill_total_atria_hr_samples=40691`, `expected_total_covered=1`,
`expected_total_reconciled=0`, and `reconciliation=overfilled`. Gate G now
surfaces `healthkit_hr_overfilled` alongside
`healthkit_hrv_reference_pending+healthkit_workout_learning` instead of treating
`readback >= expected` as success. This is the honest state: HealthKit
authorization/write/readback works, but this local HealthKit store needs a
delete/rebuild or reset path before the HR total can be called reconciled.

**Gate G update 2026-06-15 HealthKit HR reset/rebuild reconciled:** A guarded
launch-only reset path now deletes and rebuilds only Atria-authored Apple Health
heart-rate rows. The selector is constrained to the saved-session window and
matches either Atria's source bundle or `atria_session_id` metadata, while
logging independent rows separately. Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-healthkit-reset-rebuild-followup-device-verify/`
proved the cleanup path selected/deleted `48274` Atria HR rows,
preserved `0` independent rows, rebuilt `48305` HR-only rows, and promoted no
HRV/workout metrics (`metric_promotions=0`). That run removed the overfill but
exposed a planner/writer mismatch: the planner counted `214` local points that
cannot become valid HealthKit samples because their one-second window falls
outside the saved session bounds. The planner now uses the same writable-HR
sample filter as the exporter. A final physical iPhone run in
`docs/evidence/gate-g/20260615T-healthkit-reset-rebuild-reconciled-device-verify/`
built, installed, launched Atria, saved a fresh incremental HealthKit HR delta
(`hr_samples=15`), and read back the exact expected total:
`expected_total_atria_hr_samples=48320`, `readback_atria_hr_samples=48320`,
`missing_total_atria_hr_samples=0`, `overfill_total_atria_hr_samples=0`,
`expected_total_reconciled=1`, and `reconciliation=reconciled`. Gate G remains
`metric_gated`, not complete, only because HRV and workout writes are still
truth-gated by `healthkit_hrv_reference_pending+healthkit_workout_learning`.

**Gate G update 2026-06-15 session-scoped HealthKit readback:** Atria now
reconciles HealthKit HR readback using only rows whose `atria_session_id`
metadata matches the local saved-session set, while logging broad Atria-looking
rows separately. Physical iPhone evidence in
`docs/evidence/gate-g/20260615T120144-healthkit-session-scoped-readback-device-verify/`
built, installed, launched, saved a fresh HealthKit delta (`hr_samples=98`), and
read back an exact session-scoped total:
`expected_total_atria_hr_samples=48879`, `readback_atria_hr_samples=48879`,
`broad_atria_hr_samples=48879`, `scoped_atria_hr_samples=48879`,
`missing_total_atria_hr_samples=0`, `overfill_total_atria_hr_samples=0`,
`expected_total_reconciled=1`, and `scope=session_metadata`. The same run kept
HRV/workouts fail-closed (`workouts=0 hrv_samples=0`) and the reference audit
still found no independent Apple Health HR source
(`independent_hr_samples=0`). A watchdog checkpoint recovered a live standard-HR
gap and the leave-running handoff relaunched Atria in standard-HR long-wear
mode; post-run pull confirmed `process_status=running`, with the latest saved
segment carrying RR and the new active journal currently HR-only. Gate G remains
`metric_gated`, not fully complete, because the upstream Gate B/E truth gates
still block HRV and workout export.

**Gate E tooling update 2026-06-15 stitched workout audit alignment:**
`tools/analyze_workout_store.py` now mirrors Atria's on-device
`stitched_observed_chunks` workout candidate. The stitched candidate compresses
missing inter-session wall time while inserting the same 16-second reset gaps as
the Swift implementation, so Mac-side pulled-store audits rank the same best
workout evidence as `gate_status gate=E`. On the current pulled store, the best
candidate is now `stitched_observed_chunks` with the same fail-closed shape as
the device row: `stream_coverage_percent=85`, `peak=122`, `threshold=121`,
`elevated_s=3`, `required_elevated_s=1200`, `longest_bout_s=3`, and
`required_bout_s=480`. This removes a misleading offline `stream_gaps` diagnosis
but does not pass Gate E; the real blocker is insufficient sustained HRR50
workout-band time, plus sleep remains blocked by unvalidated current motion.
Physical iPhone evidence in
`docs/evidence/gate-e/20260614T234100Z-stitched-workout-audit-alignment-device-verify/`
built cleanly, launched Atria, logged Gate E with
`workout_best_source=stitched_observed_chunks`, pulled `sessions.json`, and
wrote `workout-store-analysis.txt` where the HRR50 sensitivity row now reports
`best_source=stitched_observed_chunks` and the same fail-closed `elevated_s=3`
/ `longest_bout_s=3` blocker.

**Gate E/Gate Status update 2026-06-15 post-gym store audit:** after adidshaft
returned from the gym with Atria still open and the strap still worn, a bounded
physical-iPhone pull in
`docs/evidence/gate-status/20260614T234509Z-current-store-pull-after-gym/`
captured the current local store, active journal, and historical archive. The
run confirmed useful progress without relaxing gates: Gate B has a saved
RR-ready window (`raw=368`, `kept=361`, `conf=98`, `max_gap_s=1.8`,
`rmssd=32.7`) but remains reference-pending; Gate E still refuses the gym block
as a workout because the best HRR50 stitched candidate has only `elevated_s=3`
and `longest_bout_s=3` against `required_elevated_s=1200` and
`required_bout_s=480`. `tools/analyze_sleep_store.py` now mirrors the on-device
sleep evidence contract from pulled `sessions.json` plus
`historical-archive.jsonl`. It reports two HR-only sleep candidates, including
the latest fragmented sleep fallback (`duration_s=10545`, `span_s=13706`,
`sessions=2`), but keeps them diagnostic-only with blocker
`sleep_motion_unvalidated_historical_stale` because the historical gravity
archive is March data with zero overlap against the June sleep windows. The same
evidence keeps Gate H metric fail-closed (`current_session_usable_rows=0`)
despite codec-clean historical rows. Subagent read-only cross-check of NOOP/Whoof
references found no concrete untried local command/parser path to make current
sleep motion or workout detection pass without new evidence; defer more blind
protocol churn. Follow-up verification in
`docs/evidence/gate-e/20260614T235233Z-sleep-store-audit-device-verify/`
built cleanly, launched on the physical iPhone, logged
`sleep_validation status=learning reason=sleep_motion_unvalidated_historical_stale`,
and confirmed the new sleep-store analyzer reports the same fail-closed best
candidate.

**Gate E durability update 2026-06-15 long-wear checkpoint hardening:** the
post-gym store showed only `1242s` saved HR on 2026-06-15 despite Atria being
left open, while the stronger workout-like evidence remained from the 2026-06-14
store. This rules out another metric-threshold tweak as the next smart move:
long-wear persistence needed to leave a denser trail whenever iOS delivers
background BLE events. Atria now snapshots event-driven checkpoints every `60s`
instead of `180s`, and flushes `Documents/atria-active-session.json` every `5`
accepted HR samples instead of `10`. This does not change BLE traffic, HRV,
strain, sleep, or workout readiness thresholds; it only reduces data-loss
exposure when timers are paused or the app is backgrounded. Physical iPhone
evidence in
`docs/evidence/gate-e/20260615T-long-wear-event-checkpoint-hardening-device-verify/`
built and installed the app, logged the new `session_checkpoint schedule
interval_s=60.0`, and kept Gate B/D/E fail-closed. Follow-up leave-running
evidence in
`docs/evidence/gate-e/20260615T-long-wear-event-checkpoint-hardening-leave-running/`
confirmed fresh standard `2A37` HR frames (`standard_2a37_frames=18`),
low-radio mode (`radio_low_traffic_complete=True`), the new denser journal flush
(`active_session_journal status=saved reason=accepted_hr samples=5` and later
`samples=14`), and relaunched Atria without the console
(`HARNESS_LEAVE_RUNNING status=launched`). Gate E remains partial:
sleep still needs current motion validation, and workout remains a
diagnostic-only strength/near-miss candidate until sustained-HR or independent
HR-reference evidence validates it.

**Gate E tooling update 2026-06-15 non-disruptive state pulls:** long-wear
audits now have `./pull_atria_state.sh --evidence-dir DIR`, a copy-only helper
that pulls `sessions.json`, `atria-active-session.json`, historical archive, and
process state without building, installing, launching, terminating, or changing
BLE state. This avoids invalidating the very unattended collection being
audited. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-nondisruptive-state-pull-freshness-device-verify/`
copied all three files while Atria's process was still listed as running. The
pull proved the new active journal path exists and can contain real RR
(`active_journal_samples=17`, `active_journal_rr_values=19`), but also exposed a
more precise current blocker: the journal was stale
(`active_journal_age_s=199`, `active_journal_freshness=stale`). A running
process is therefore not sufficient evidence of active collection. Future
long-wear checkpoints must use this helper before relaunching, and should treat
`active_journal_freshness=stale` as a collection-continuity blocker rather than
as a metric failure.

**Gate E tooling update 2026-06-15 active collection freshness:** Atria now
surfaces active collection freshness inside its own diagnostic evidence, not
only in the Mac pull helper. `ActiveSessionJournal.evidence()` reports
`active_journal_freshness`, `active_collection_status`, and
`active_collection_blocker`, using a `90s` freshness limit so a live process
cannot be mistaken for active capture when the journal is stale or missing.
Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-active-collection-freshness-device-verify/`
built, installed, and launched Atria, restored and closed the previous stale
journal safely (`active_session_journal status=cleared
reason=stale_journal_restore ... samples=17 ... rr_values=19`), and logged the
new fail-closed fields (`active_collection_status=no_journal`,
`active_collection_blocker=active_journal_missing`). The short verification did
not reconnect to the strap (`standard_2a37_frames=0`), so it promoted no
metrics. Follow-up evidence in
`docs/evidence/gate-e/20260615T-active-collection-freshness-leave-running/`
relaunched Atria without rebuilding, confirmed standard `2A37` HR frames,
logged a fresh journal (`active_journal_freshness=fresh`,
`active_collection_status=active`, `active_collection_blocker=none`), and left
the app running on the cabled iPhone (`HARNESS_LEAVE_RUNNING status=launched`,
PID `35583`). Gate E remains partial, but the collection-continuity blocker is
now explicit on device.

**Gate E tooling update 2026-06-15 phone-motion audit wiring:** Atria now
records iPhone CoreMotion accelerometer deltas as explicit `phone_motion_*`
audit fields on saved sessions and checkpoint logs, with
`phone_motion_wrist_validated=0` and `phoneMotionValidated=false`. This is only
debug-rig corroboration: it must not validate wrist motion, sleep, workout,
HRV, recovery, trends, or HealthKit metrics. The code builds cleanly and the
physical iPhone install succeeded in
`docs/evidence/gate-e/20260615T-phone-motion-audit-device-verify/`, but the
launch/WHOOPDBG verification was blocked because the iPhone was locked
(`FBSOpenApplicationErrorDomain error 7`, `reason: Locked`). A no-console
launch retry failed for the same reason. This checkpoint is therefore not
device-verified and does not pass Gate E; rerun the physical launch after the
iPhone is unlocked to collect `WHOOPDBG phone_motion` and
`session_checkpoint ... phone_motion_*` evidence.

**Gate E tooling update 2026-06-15 phone-motion sampled verification:** the
phone-motion audit now logs direct sampler summaries as
`WHOOPDBG phone_motion status=sampled`, so CoreMotion delivery can be verified
without depending on a saved HR segment. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-phone-motion-sampled-device-verify/` built,
installed, and launched Atria, then confirmed the sampler on-device:
`samples=15`, `mean_delta_g=0.001`, `max_delta_g=0.002`,
`over_still_threshold=0`, `still_threshold_g=0.030`,
`validated=0`, and `wrist_motion_validated=0`. Follow-up leave-running evidence
in `docs/evidence/gate-e/20260615T-phone-motion-sampled-leave-running/`
confirmed the same sampler (`max_delta_g=0.003`), real `2A37` RR
(`standard_2a37_rr_values=23`), a fresh active journal
(`active_collection_status=active`, `active_collection_blocker=none`), and left
Atria running on the cabled iPhone as PID `35790`. Gate E remains partial:
phone motion is debug-rig corroboration only, sleep still needs validated
current wrist/strap motion or a documented accepted fallback, and workout still
needs sustained-HR or independent HR-reference evidence.

**Gate status tooling update 2026-06-15 phone-motion pull summary:** the
copy-only `./pull_atria_state.sh --evidence-dir DIR` helper now reports saved
phone-motion audit coverage directly: `phone_motion_sessions`,
`phone_motion_nonzero_sessions`, latest phone-motion fields, and latest nonzero
phone-motion fields. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-phone-motion-pull-nonzero-summary-device-verify/`
verified the pull while Atria stayed running: `process_status=running`,
`active_journal_freshness=fresh`, `phone_motion_sessions=5`,
`phone_motion_nonzero_sessions=1`, and the latest nonzero audit block had
`samples=21`, `mean_delta_g=0.0013624043313197848`,
`max_delta_g=0.002240601334120985`, `over_still_threshold=0`,
`phone_motion_validated=0`, and `wrist_motion_validated=0`. This improves
status visibility only; it does not pass Gate E because the motion source is
still phone CoreMotion audit data, not validated strap/wrist motion.

**Gate E durability update 2026-06-15 checkpoint persistence status:** checkpoint
callbacks now return the `SessionStore.checkpoint` result, so watchdog,
scheduled, RR-quality, and event-driven checkpoint logs report `status=saved`
only after the store write succeeds; failures report `status=store_failed` while
the active journal is still flushed for recovery. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T112637-checkpoint-persistence-status-device-verify/`
built, installed, and launched Atria, then the focused run verified live 2A37 RR
(`standard_2a37_rr_values=19`), a successful checkpoint store write
(`session_store_save status=ok op=checkpoint ... samples=18 duration_s=16`), the
new truthful checkpoint row (`session_checkpoint status=saved
reason=no_data_watchdog samples=18 rr_samples=19`), and a saved recovery journal
(`active_session_journal status=saved reason=no_data_watchdog_checkpoint
samples=18 rr_values=19`). The harness relaunched Atria in low-radio long-wear
mode (`HARNESS_LEAVE_RUNNING status=launched`), and the post-run copy-only pull
confirmed `process_status=running`, `sessions_count=233`, and a fresh active
journal (`active_journal_freshness=fresh`, `active_journal_samples=5`). This is a
collection-durability fix only: Gate E remains partial because the same
on-device status row kept workout fail-closed
(`saved_workout_ready=0`, `saved_workout_blocker=insufficient_elevated_time`)
and sleep still lacks validated current wrist/strap motion.

**Gate status tooling update 2026-06-15 active RR pull summary:** the copy-only
state pull now reports `latest_session_rr_points`, `latest_session_rr_status`,
`active_journal_rr_status`, and active-journal RR gap/coverage fields. Physical
iPhone evidence in
`docs/evidence/gate-status/20260615T113225-active-rr-pull-summary-device-verify/`
verified the helper while Atria stayed running: `process_status=running`,
`active_journal_freshness=fresh`, `latest_session_points=27`,
`latest_session_rr_points=0`, `latest_session_rr_status=hr_only`,
`active_journal_samples=27`, `active_journal_rr_values=0`,
`active_journal_rr_status=hr_only`, and
`active_journal_rr_coverage_3s_percent=0`. This is a faster fail-closed
diagnostic for unattended pulls: the app is collecting live HR locally, but the
current active segment is not HRV-capable until real RR/IBI frames arrive. Gate
B remains reference-pending and Gate E remains partial.

**Gate B/E durability update 2026-06-15 RR presence watchdog:** Atria now has a
specific long-wear watchdog for the case where accepted standard `2A37` HR keeps
arriving but RR/IBI is stale or absent. It persists `rr_presence_*` fields into
the gate-status evidence, checkpoints the active journal before recovery, first
reasserts notification/read on `2A37`, and escalates the second consecutive
HR-only RR stall to a fresh-scan reconnect. The recovery path is explicitly
`hrv_policy=learning_only`: it never estimates RR or HRV from HR-only frames.
Physical iPhone evidence in
`docs/evidence/gate-b/20260615T113655-rr-presence-watchdog-device-verify/`
built, installed, and launched Atria. The first run proved the new evidence
fields and schedule, and the retuned run verified `timeout_s=24.0` on device.
That retuned run collected real `2A37` RR early
(`standard_2a37_rr_values=27`, `max_rr_log_gap_s=1.7`) and saved a checkpointed
RR-present session (`latest_session_rr_points=25` in the post-run pull), but it
also showed the current failure mode was a broader standard-HR notification
stall after `19` accepted samples, handled by the existing accepted-HR watchdog
(`checkpoint=saved`, `action=fresh_scan_reconnect`). The leave-running relaunch
was confirmed with `process_status=running`; its fresh active journal was
HR-only (`active_journal_rr_values=0`), so the next unattended segment remains
fail-closed until real RR resumes or the RR-presence watchdog fires. This is a
recovery and diagnostic improvement only: Gate B remains reference-pending
because the external RR/IBI RMSSD comparison is still missing, and Gate E
remains partial.

**Gate G update 2026-06-15 post-permission HealthKit reconciliation:** after
Health write permission was granted on the physical iPhone, the narrow
HealthKit-only run in
`docs/evidence/gate-g/20260615T114729-post-permission-healthkit-single-device/`
exported the single-device local backlog without promoting gated metrics:
`healthkit_export status=saved ... hr_samples=461 workouts=0 hrv_samples=0`.
Readback then reconciled exactly (`expected_total_atria_hr_samples=48781`,
`readback_atria_hr_samples=48781`, `missing_total_atria_hr_samples=0`,
`overfill_total_atria_hr_samples=0`, `reconciliation=reconciled`,
`data_appears=1`). The same run confirmed the external HR reference is still
missing (`independent_hr_samples=0`), so Gate D remains partial and HealthKit
does not become a self-reference. Atria was relaunched in standard-HR-only
long-wear mode after the export.

**Gate B/E durability update 2026-06-15 RR-triggered journal flush:** real RR/IBI
arrival now also touches the debounced active-session journal flush path. This
closes a single-device durability gap where a clean RR burst could be appended
to memory but wait for a later HR/checkpoint event before becoming durable. The
flush remains fail-closed and local-only: it stores decoded RR already received
from `2A37`/protocol frames and never estimates RR from HR-only samples. Physical
iPhone evidence in
`docs/evidence/gate-b/20260615T114949-rr-triggered-journal-flush-device-verify/`
built, installed, and launched Atria, then confirmed repeated RR-triggered disk
writes (`active_session_journal status=saved reason=rr ... rr_values=4`,
`10`, `13`, `18`, `21`) while standard `2A37` RR climbed to
`standard_2a37_rr_values=27`. The copy-only post-run pull confirmed Atria was
left running, the latest saved segment was RR-present
(`latest_session_rr_points=26`), and the fresh active journal was also
RR-present (`active_journal_rr_values=15`, `active_journal_rr_coverage_3s_percent=100`).
This improves Gate B/E durability only; Gate B still requires the external RR
reference comparison and Gate E still requires real sustained workout/sleep
validation.

**Gate B/E status update 2026-06-15 active-journal replay:** Gate Status replay
now treats a fresh active journal as an opt-in virtual current session for RR
ledger and workout-readiness diagnostics. This lets the cabled iPhone evaluate
the still-running segment immediately instead of waiting for a disconnect,
checkpoint, or final save. The virtual session is used only in replay evidence
(`rr_replay_active_journal=1`, `workout_replay_active_journal=1`); HealthKit
exports, daily rollups, trends, and saved-session history remain saved-session
only. The active journal is marked unvalidated and must pass the same RR,
workout, and reference gates as any saved segment before a metric can promote.
Fast Gate Status also now bounds workout replay on large local stores, after the
242-session full replay was killed by iOS before emitting B/E rows. Physical
iPhone evidence in
`docs/evidence/gate-status/20260615T115709-active-journal-bounded-replay-device-verify/`
built, installed, and launched Atria, completed Gate Status, and confirmed
`rr_replay_active_journal=1`, `workout_replay_active_journal=1`, and
`workout_replay_scope=bounded_large_store`. That launch correctly closed the
previous stale journal before replay; the leave-running relaunch then produced a
fresh RR-present active journal in the copy-only pull
(`active_journal_rr_values=12`, `active_journal_rr_coverage_3s_percent=100`,
`process_status=running`). Gate B remains reference-pending and Gate E remains
partial.

**Gate B/E durability update 2026-06-15 segment HR-only RR recovery:** current
single-device state after the session-scoped HealthKit pass showed Atria still
running, with the latest saved segment carrying RR but the fresh active journal
stuck in HR-only mode (`active_journal_samples=43`, `active_journal_rr_values=0`,
`active_journal_rr_coverage_3s_percent=0`). The RR presence watchdog now treats a
new active segment with fresh HR samples and zero segment RR as
`segment_hr_only`, measuring the RR gap from the segment's first HR sample
instead of an older global RR timestamp. The `2A37` handler also triggers this
same recovery path event-by-event after 12 seconds of fresh segment HR with zero
segment RR: first reassert/read notify, then fresh scan-and-connect on repeated
segment HR-only evidence after saving the active journal. This does not pass
Gate B and does not estimate HRV from HR-only frames; it makes long-wear
collection recover faster when the strap emits HR without R-R intervals.

**Gate B status-priority update 2026-06-15 current RR continuity:** Atria now
exposes typed active-journal RR diagnostics to Gate Status, so the execution
priority can distinguish a saved historical clean RR candidate from the current
single-device stream quality. If the fresh active journal has HR/RR samples but
fails the live Gate B continuity rule (`duration >= 300s`, `rr >= 240`,
`max_rr_gap <= 3s`, `coverage >= 90%`), `WHOOPDBG execution_priority` reports
`next_local_gate=B` and a concrete local blocker such as
`B:current_rr_continuity_gap_31s_coverage_1p`. Physical iPhone verification in
`docs/evidence/gate-status/20260615T-rr-continuity-local-priority-device-verify/`
built, installed, launched Atria, restored the active journal, and logged
`active_journal_rr_values=12`, `active_journal_rr_max_gap_s=31.0`,
`active_journal_rr_coverage_3s_percent=1`, with Gate B still
`reference_pending`. The app still preserves the saved clean candidate
(`raw=368`, `kept=361`, `conf=98`, `max_gap_s=1.8`) for later external
RR/IBI comparison, but the current one-device work is now correctly aimed at
restoring continuous `2A37` RR before another reference attempt.

**Gate B/E durability update 2026-06-15 early HR-continuity reconnect:** the
current RR-continuity evidence showed `2A37` callbacks stalling long enough for
31-second and 91-second RR gaps. Reasserting notification alone did not restore
the stream before the Gate B window was broken. The HR-continuity watchdog now
escalates to a fresh scan-and-connect when the raw `2A37` gap survives a full
second watchdog window (`raw_gap >= max(timeout * 2, timeout + 6)`), after
flushing the active journal. Fresh-scan reconnect requests are logged before
CoreBluetooth cancellation, immediately start a fresh scan, and keep 1-second
fallback scans as backup if iOS does not deliver a timely disconnect callback.
This keeps the no-fake-HRV policy unchanged: metrics remain `learning` unless
real RR resumes with no `>3s` gap and later passes the external RR/IBI
reference.

**Gate B/E durability update 2026-06-15 RR-present-to-HR-only recovery:** the
follow-up physical iPhone run showed a different current failure: standard
`2A37` packets kept arriving, but with `rrnum=0` after the active segment had
already collected real RR. Atria now treats that as a stronger continuity loss:
if `rr_presence_watchdog` sees `hr_only` after the segment already has real RR,
it fresh scan-connects immediately instead of waiting for a second watchdog
cycle. Segments that never had RR still get the gentler first reassert/read
path. HRV remains `learning`; the app never estimates RR from HR-only frames.

**Gate B/E durability update 2026-06-15 current RR gap sentinel:** a fresh
one-device gate-status run showed current live `2A37` HR samples with
`rrnum=0` from the start of the segment, and the immediate fresh-reconnect
startup policy created avoidable BLE churn. Atria now holds the standard-HR
connection first: `segment_hr_only` requires a repeated failure before fresh
scan, and HR-continuity uses a faster `6s` stale-data check that first
reasserts/reads `2A37` before escalating. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-current-rr-gap-sentinel-device-verify/` built,
installed, and launched on the cabled iPhone, verified
`hr_continuity_watchdog schedule timeout_s=6.0 interval_s=3.0`, then logged
`hr_continuity_watchdog status=stale ... action=reassert_notify` followed by
fresh-scan escalation only after no new standard-HR data arrived. This is a
recovery policy only. It does not promote saved RR, HR samples, or historical
data into live HRV; current HRV stays `learning` until real RR returns.

**Gate B/E durability update 2026-06-15 RR-presence refresh on real intervals:**
Gate Status no longer lets old `segment_hr_only`/`hr_only` RR-presence evidence
survive after real `2A37` RR/IBI resumes. Every real RR arrival now refreshes
the persisted `rr_presence_*` fields at a 5-second throttle with
`status=rr_present`, `action=observe_real_rr_0x2A37`, current RR count, and the
latest observed RR gap. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-rr-presence-refresh-device-verify/` hit the
known Xcode destination failure (`observing system notifications failed`), then
proved the generic iOS build plus `devicectl` install/launch fallback worked.
The run logged fresh RR presence (`rr_presence_values=19`, `rr_presence_age_s=0.5`)
and a fresh active journal (`active_journal_rr_values=17`,
`active_journal_rr_coverage_3s_percent=100`) while keeping Gate B
`reference_pending` because the external RR/IBI comparison is still missing.
This is a diagnostic truth fix only; it does not relax the clinical Gate B
contract or estimate HRV from HR-only frames.

**Gate B/E durability update 2026-06-15 RR-presence fresh reconnect policy:**
The RR-presence watchdog's fresh-scan branch was still unreachable in code even
though the docs and recent evidence expected it. Atria now fresh scan-connects
when a long-wear segment has accepted `2A37` HR but no segment RR
(`segment_hr_only`), when an RR-present segment falls back to HR-only, or when
the RR-presence stall repeats. The old notify/read reassert path remains only
for missing-characteristic/unsupported-operation cases. A debug-only harness
flag, `--force-rr-presence-watchdog-after`, now exercises the same production
recovery path on the cabled iPhone, and RR-presence `accepted_gap_s` is clamped
to zero so backdated RR beat timestamps do not produce impossible negative
diagnostics. Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-rr-presence-fresh-reconnect-device-verify/`
built green through the generic iOS fallback, installed, launched, restored real
standard `2A37` RR immediately after fresh scan, and logged
`active_journal_rr_values=25`, `active_journal_rr_coverage_3s_percent=100`,
with Gate B still `reference_pending`. A focused forced-reconnect run in
`docs/evidence/gate-b/20260615T-rr-presence-forced-reconnect-device-verify/`
logged the new harness flag and on-device `rr_presence_action=fresh_scan_reconnect`;
after the interrupted console proof, Atria was relaunched cleanly and
`processes-after-clean-relaunch.txt` confirms it is running. A follow-up clamp
proof in
`docs/evidence/gate-b/20260615T-rr-presence-clamped-gap-device-verify/` rebuilt,
installed, launched, logged `rr_presence_accepted_gap_s=0.0`, restored real
`2A37` RR, and left Atria running again. This is a single-device continuity
improvement only: HRV/Recovery remain `learning` until the saved/live RR package
is compared to an independent RR/IBI reference.

**Gate B/E usability update 2026-06-15 current-segment RR honesty:** the
Collection card and `collection_reliability_ui` log no longer count old
RR-presence ledger values as current RR. `rr_present` now means the active
journal has current RR/IBI. If a rollover has left only saved RR evidence, the
UI/log reports `saved_rr_only`; if the current active journal has accepted HR
but no RR, it reports `segment_hr_only`. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-current-segment-rr-honesty-device-verify/`
built, installed, launched, and logged `rr_present=0
rr_presence_status=saved_rr_only` after a rollover, then `rr_present=0
rr_presence_status=segment_hr_only` once the current segment had five accepted
HR samples and zero RR values. The same launch kept `today_usability
rr_package_ready=1`, so saved RR packages remain usable while current HRV stays
`learning` unless real current RR returns and external reference validation is
provided.

**Gate Status/G usability update 2026-06-15 upstream Gate G router:** bounded
Gate Status no longer reports Gate G as the next local task when the platform
side is already proven and the only remaining Gate G blockers are upstream
truth gates such as `healthkit_hrv_reference_pending` or
`healthkit_workout_learning`. Those blockers still appear on the Gate G row;
they are not hidden or treated as passes. The execution router now sends the
next local step to Gate E targeted sleep/workout diagnostics, with Gate H as
secondary protocol work, unless there is a real HealthKit/readback repair to do.
Gate Status also writes a durable local snapshot at
`Documents/atria-gate-status.txt`, and the harness pulls it with
`--pull-sessions`, so physical verification survives `devicectl --console`
failures. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-execution-router-snapshot-immediate-device-verify/`
installed and launched Atria, pulled the snapshot, and showed Gate G
`status=metric_gated`, `platform_ready=1`,
`metric_blockers=healthkit_hrv_reference_pending`, followed by
`execution_priority ... next_local_gate=E
next_local_action=run_targeted_sleep_or_workout_diagnostics`. No gate was
promoted. Follow-up evidence in
`docs/evidence/gate-status/20260615T-execution-router-harness-pull-device-verify/`
proved the harness pull path by logging `WHOOPDBG_GATE_STATUS_PULL_FILE` and
left Atria running in long-wear mode. This is execution hygiene for faster
single-device progress.

**Gate E tooling update 2026-06-15 workout capture contract:** the Gate E
workout presets now print a `HARNESS_GATE_E_WORKOUT_CONTRACT` block before the
device launch. The banner records the intended radio mode, label, capture
duration, current expected target HR floor (`121 bpm` for the present profile),
the app-side threshold field that remains authoritative, required continuous
elevated bout (`480s`), total target duration (`600s`), minimum stream coverage
(`75%`), success fields, and fail-closed rules. This is execution hardening for
the next real workout with the single strap/iPhone setup. Physical iPhone smoke
evidence in
`docs/evidence/gate-e/20260615T-workout-contract-device-verify/` built,
installed, launched Atria, and logged the standard-HR-only workout schedules at
`threshold_hr=121`. The short smoke intentionally did not pass Gate E: it ended
before delayed Gate status/backup checks completed, no workout was detected, and
no HealthKit workout write was attempted. A longer rerun in
`docs/evidence/gate-e/20260615T-workout-contract-device-verify-2/` was blocked
before install by the cabled phone becoming unavailable to Xcode/development
services. Gate E still requires a real physical workout that logs
`workout_saved_ready=1` / `live_workout_ready=1` with a sustained elevated-HR
window and no detector relaxation.

**Gate E tooling update 2026-06-15 focused validation reducer:** focused
sleep/workout verifier launches now have the same fail-closed harness semantics
as the other targeted gates. `live_device_debug.sh --verify-sleep` and
`--verify-workout-label` wait for the corresponding `WHOOPDBG sleep_validation`
/ `WHOOPDBG workout_validation` rows and fail with
`HARNESS_ERROR=sleep_validation_incomplete` or
`HARNESS_ERROR=workout_validation_incomplete` if the row is absent. The reducer
now synthesizes a focused Gate E row from those logs. Physical iPhone evidence
in `docs/evidence/gate-e/20260615T-focused-validation-reducer-device-verify/`
built, installed, and launched Atria, then logged
`sleep_validation_complete=True` and `workout_validation_complete=True`. The
current truthful Gate E row is `partial`: sleep has an HR-only fragmented
fallback (`duration_s=10545`, `chunks=2`) but remains blocked by
`sleep_motion_unvalidated_historical_stale`, while the best `Long wear`
workout aggregate remains a diagnostic near-miss/strength candidate only
(`stream_coverage_percent=37`, `peak_hr=122`, `threshold_hr=121`,
`elevated_s=3`, `required_elevated_s=1200`, `longest_bout_s=3`,
`required_bout_s=480`). This shortens future execution loops without relaxing
sleep/workout confidence gates.

**Gate G update 2026-06-15 Atria backup path verification:** stale docs still
described the old `Documents/whoop-backups/` path even though the implementation
writes Atria-named backups and keeps legacy paths readable for restore/verify.
The docs now state the current contract: new backups write to
`Documents/atria-backups/`, while legacy `Documents/whoop-backups/` files remain
readable. Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-atria-backup-path-device-verify/` built,
installed, launched Atria, wrote
`session_backup path=Documents/atria-backups/atria-sessions-20260615T073015Z-debug.json`,
verified it with `session_backup_verify status=ok ... digest_match=1`, and the
harness completed with `backup_complete=True` and `backup_verify_complete=True`.
This verifies backup durability/naming only; Gate G remains metric-gated by HRV
reference and workout readiness.

**Gate execution update 2026-06-15 device destination preflight:** a fresh
current gate audit can be blocked by Xcode's destination-service layer even when
CoreDevice can still use the cabled iPhone. The known Xcode text is
`observing system notifications failed`. `live_device_debug.sh` runs
`xcodebuild -showdestinations` with a short destination timeout before building,
and the real build also uses `-destination-timeout 10`. When that Xcode message
appears during either preflight or the physical-destination build, the harness
now cross-checks `devicectl device info details`: if the phone is paired, wired,
booted, and Developer Mode enabled, it logs
`HARNESS_DEVICE_PREFLIGHT_DEVICE status=ready`, classifies the event as
`xcode_notification_observe_false_negative`, and continues via the signed
`generic/platform=iOS` build plus `devicectl` install/launch path. Only real
device-service failures should block the run. This does not pass any metric gate;
it makes the required real-device verification loop faster and more honest.
Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-xcode-notification-false-negative-device-verify/`
captured the false-negative classification and fallback build/install path;
`docs/evidence/gate-status/20260615T-xcode-notification-false-negative-snapshot-device-verify/`
then launched Atria without depending on console streaming and pulled
`Documents/atria-gate-status.txt` from the real app container.

**Gate execution update 2026-06-15 large-store bounded status:** the current
273-session store made the fast Gate Status audit unsafe: the app logged
`gate_status_start` and then iOS killed it with signal 9 before
`execution_priority`. Fast Gate Status now treats large stores as a bounded
checkpoint path. It emits cheap counters plus backup/radio/journal evidence,
explicitly marks RR/workout replay, HealthKit diagnostics, historical archive,
sleep, and trend replay as `skipped_bounded_audit`, and keeps metrics
fail-closed. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-bounded-large-store-status-direct-install-verify/`
built a signed Atria app, installed it on the cabled iPhone, launched it, and
logged `gate_status_progress stage=bounded_fast_large_store`,
`gate_status_complete=True`, `backup_verify_complete=True`, and
`radio_low_traffic_complete=True` without the signal-9 crash. Current truth
after the bounded audit: Gate B is still `reference_pending` because external
RR/IBI validation is missing; Gate C is learning with `0/7` validated HRV
baseline; Gate D is partial because the CSV/HealthKit external HR reference is
not valid (`csv_reference_status=fail`, `pairs=10`); Gate E/F need targeted
real-world diagnostics/history; Gate G/H are not replayed in this fast audit and
must be checked with their dedicated diagnostics before being called ready.

**Gate execution update 2026-06-15 bounded analyzer clarity:** the bounded fast
Gate Status rows deliberately skip replay-heavy Gate E/F/G/H diagnostics, but
the Mac reducer previously interpreted those omitted fields as generic missing
sleep/workout/history evidence. `tools/analyze_gate_status.py` now recognizes
`skipped_bounded_audit` and reports the correct next actions: targeted
sleep/workout diagnostics for Gate E, `--log-trends` for Gate F, dedicated
HealthKit readback diagnostics for Gate G, and targeted historical archive
diagnostics/pulls for Gate H. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-bounded-analyzer-clarity-device-verify/`
launched the installed Atria app with `--log-gate-status`, logged
`gate_status_progress stage=bounded_fast_large_store`, verified the latest
backup (`digest_match=1`), and produced analyzer output with explicit
`*_skipped_bounded_audit` blockers. Regression checks against older non-bounded
gate logs still preserve the detailed Gate E near-miss and Gate H
metric-fail-closed blockers.

**Gate E/F targeted status 2026-06-15:** after the bounded audit, a targeted
physical iPhone launch in
`docs/evidence/gate-status/20260615T-targeted-ef-diagnostics-device-verify/`
ran daily rollups, workout preflight, sleep validation, trend windows, backup
verify, and low-radio BLE. It confirmed that Gate E is blocked by real detector
evidence, not by missing tooling: sleep has two low-confidence HR-only
candidates, with the latest fragmented fallback at `10545s` duration and
`13706s` span, but `sleep_validation status=learning
reason=sleep_motion_unvalidated_historical_stale` because motion is not decoded
and the historical gravity window is stale by roughly 6.57 million seconds. The
best saved workout aggregate covers `20784s` with `85%` stream coverage, but
only `3s` above the HRR50 threshold against `1200s` required and a longest bout
of `3s` against `480s` required; it remains a diagnostic-only strength
candidate until an independent HR reference proves wrist under-reporting or a
future workout produces sustained elevated HR. Gate F also remains learning:
trend windows reported `coverage_days=3` with required coverage `5/21/63` for
7/30/90-day windows and blockers
`coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
The same run showed live standard `2A37` RR briefly resumed
(`standard_2a37_rr_values=7`) but the active segment still had an RR gap
(`hrv_max_rr_gap_s=37.8`), so Gate B remains external-reference and continuity
gated.

**Gate G targeted status 2026-06-15:** a dedicated physical iPhone run in
`docs/evidence/gate-g/20260615T-dedicated-platform-readback-device-verify/`
verified the platform/readback path without relying on bounded Gate Status.
HealthKit export wrote `716` incremental Atria HR samples and
`healthkit_export_verify status=ok` reported `readback_covers_delta=1`,
`expected_total_covered=1`, `expected_total_reconciled=1`,
`missing_total_atria_hr_samples=0`, `overfill_total_atria_hr_samples=0`, and
`data_appears=1`. The HealthKit reference audit correctly rejected Apple Health
as an HR reference because all `48879` HR samples in the window were
Atria-authored (`independent_hr_samples=0`, `external_reference_ready=0`).
Widget/app-group/complication plumbing logged ready (`app_group=1`,
`widget_target=1`, `complication_target=1`), backup verify passed with
`digest_match=1`, low-radio mode was ready, and notification scheduling was
authorized but scheduled zero production notifications because recovery remains
learning, strain is gated by recovery confidence, and battery was `41%`. The
app later terminated with signal 9 after these requested diagnostics completed;
the evidence is sufficient for Gate G platform/readback status, but Gate G
remains `metric_gated` on `healthkit_hrv_reference_pending` and
`healthkit_workout_learning`.

**Gate tooling update 2026-06-15 HealthKit fallback reducer:** the dedicated
Gate G log does not emit a normal `gate_status gate=G` row, so
`tools/analyze_gate_status.py` now parses `healthkit_export`,
`healthkit_export_verify`, and `healthkit_reference_audit` rows when
synthesizing fallback status. The reducer now reports Gate G as
`metric_gated` with blockers
`healthkit_hrv_reference_pending+healthkit_workout_learning` instead of
incorrectly claiming the HealthKit entitlement is missing.

**Gate H probe isolation 2026-06-15:** after long-wear collection,
`docs/evidence/gate-h/20260615T-single-device-noop-backfill-current-recheck/`
showed the NOOP-style `1400,6000,1600` historical probe was being interrupted by
Atria's own long-wear watchdog reconnects. The fixed build in
`docs/evidence/gate-h/20260615T-history-probe-watchdog-suppressed-device-verify/`
was installed and launched on the physical iPhone, kept the history-only BLE
window attached, received live `0x2f` historical rows, and pulled a `50`-row
codec-clean archive. Watchdogs logged
`action=suppressed_history_only_probe` rather than reconnecting. The selected
history is still stale March 29 data with no current-session overlap, so this is
a protocol-harness improvement, not an HRV/sleep/workout metric pass.

**Gate H/E active-motion result row 2026-06-15:** Atria now logs a delayed
`active_motion_imu_check` outcome row for the physical-device active-motion
preset, configurable with `--whoop-active-motion-result-after N`. The verified
cabled iPhone run in
`docs/evidence/gate-h/20260615T-active-motion-result-row-device-verify/` built,
installed, launched, connected BLE, enabled the full custom notify set, sent
START, and produced `status=no_strap_motion_signal` at `45s`:
`protocol_packets=3`, `protocol_imu_frames=0`,
`protocol_diagnostic_frames=0`, `sleep_motion_hint_count=0`, and
`metric_promotions=0`. This makes the single-device current-motion experiment
decidable without replay-heavy Gate Status. It does not pass Gate E/H or prove
all motion triggers impossible; it records that this unattended still run did
not expose strap-side current motion, so sleep/workout motion remains
fail-closed until deliberate active-motion evidence, a current historical
selector, or external protocol evidence exists.

**Gate F verifier checkpoint 2026-06-15:** the focused trend verifier now has
current physical-device evidence and a reducer output. The run in
`docs/evidence/gate-f/20260615T-trend-harness-completion-device-verify/`
produced a synthesized Gate F row with status `learning` and blocker
`coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
This advances execution reliability for Gate F, but the gate remains incomplete
until real saved history covers the required 7/30/90-day windows and HRV/Recovery
points are reference-validated.

**Gate D verifier checkpoint 2026-06-15:** the focused strain verifier now has
current physical-device evidence and a reducer output. The run in
`docs/evidence/gate-d/20260615T-strain-harness-completion-device-verify/`
produced a synthesized Gate D row with status `partial` and blocker
`stream_coverage_below_75_percent+missing_high_zone_exposure+max_hrr_below_85_percent+external_hr_reference_missing`.
This advances execution reliability for Gate D; the gate still requires an
independent HR reference and a real rest-to-max effort with enough stream
coverage, high-zone exposure, and max HR reserve.

**App usability checkpoint 2026-06-15:** Atria now opens to a cheap, useful
`Today` card instead of making the first viewport wait on full sleep/workout/
trend/gate replay. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-stable-hr-first-device-verify/` built,
installed, launched, logged `WHOOPDBG today_usability`, connected to the strap,
and received real `2A37` HR/RR packets. Long-wear standard-HR mode now holds a
healthy HR connection and reasserts/reads `2A37` when RR is absent instead of
fresh-scan reconnecting just to hunt HRV. This should reduce avoidable Bluetooth
churn around other accessories while keeping HRV honestly in `learning` when RR
continuity is insufficient.

**Gate H tooling checkpoint 2026-06-15:** the history/probe launcher and
historical-archive reducer now fail closed more aggressively. Explicit
historical/probe requests count as pending post-gate work, so the harness no
longer exits early just because a stale archive can be pulled; it waits for live
`0x2f` frames or the requested capture timeout. Physical iPhone evidence in
`docs/evidence/gate-h/20260615T-history-probe-early-exit-fix-device-verify/`
built, installed, launched, ran `--whoop-history-only-probe`, sent `0x22`,
received a command response, and verified watchdog reconnect suppression during
the probe. No live `0x2f` frames arrived in the minimal run, and the broader
`1400,6000,1600` init sweep was killed before app logs, so Gate H does not
advance. `tools/analyze_gate_status.py` now reports stale local archive-only
analysis as Gate H `partial` unless explicit stored-transfer/codec evidence is
present.

**Gate H app-honesty checkpoint 2026-06-15:** the in-app dashboard/gate-status
path now matches the stricter reducer: stale local historical archive evidence
is diagnostic, not a ready Gate H protocol exit. Physical iPhone evidence in
`docs/evidence/gate-h/20260615T-app-gate-h-honesty-device-verify/` built,
installed, launched, and logged `gate_status gate=H status=partial` plus
`execution_priority ... H:historical_status_skipped_bounded_audit`. Gate H stays
partial until targeted historical diagnostics show current usable transfer data
or a new sensor stream is decoded and validated.

**Gate H current-selector recheck 2026-06-15:** the NOOP/WHoof-style
`1400,6000,1600` history-only path was re-run on the cabled physical iPhone in
`docs/evidence/gate-h/20260615T-noop-backfill-current-selector-recheck-device-verify/`.
The run built, installed, launched, held the history-only probe window, synced
the strap clock (`drift_s=1`), ACKed through `0x16` (`06020b0000`), emitted `50`
app-level `historicalData` payloads, and pulled a `100`-row local archive. The
quiet-log analyzer and launcher now count `WHOOPDBG historicalData` rows, so
quiet probes no longer misreport true downloads as `historical_2f_frames=0`.
The result still rules out metric use: the corrected historical range remains
March 29, 2026, with `current_session_usable_rows=0` and
`metric_usable_rows=0`. Stop spending single-device time on blind historical
selector churn; keep the historical transport as validated protocol evidence
only and push usable-app work through HR-first logging, Today/status clarity,
HealthKit readback, backup, and reference-import flows until a new selector
source appears.

**Gate H harness verification note 2026-06-15:** a follow-up cabled-iPhone
build/install/launch in
`docs/evidence/gate-h/20260615T-quiet-history-row-count-device-verify/` verified
the updated harness in the live environment, but the strap timed out after the
`0x60` ACK and before a `0x16` response or new `historicalData` rows. This is
recorded as a BLE timeout, not a selector result, and was intentionally not
retried.

**Execution-priority checkpoint 2026-06-15:** fast gate status now separates
external blockers from local next diagnostics. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-actionable-local-priority-device-verify/`
built, installed, launched, and logged `execution_priority next_gate=B` while
keeping B/C/D blocked by external RR/HR reference. The same row now provides
`next_local_gate=H` with
`run_targeted_historical_diagnostics_then_healthkit_readback_if_needed` and
`secondary_local_gate=G`, so single-device work has an explicit next local path
without pretending reference-gated metrics are complete.

**Execution-priority update 2026-06-15 usable local routing:** after the
current-selector recheck proved the single-device historical path still returns
stale March rows, Atria no longer routes bounded fast audits back into blind
Gate H selector churn. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-usable-local-priority-routing-device-verify/`
built, installed, launched, connected to `ADIDSHAFT'S WHO`, and logged
`execution_priority next_gate=B next_action=restore_current_rr_continuity_before_external_reference`
because the active journal had `43` HR samples but `0` RR values. The same row
now routes usable local follow-up to `secondary_local_gate=G` with
`run_healthkit_readback_after_rr_presence`, keeps
`H:historical_metrics_fail_closed` in `diagnostic_only`, and preserves
`skip=no_start_retry_no_blind_history_selector_no_fake_metrics`. The bounded
Gate H row now says `action=skip_blind_history_selector_until_new_evidence`;
the Mac reducer mirrors this with “skip blind historical selector retries unless
new selector/sniffer evidence or a new sensor decode path appears.” No metric
gate is promoted by this checkpoint.

**App usability checkpoint 2026-06-15, fast workout evidence:** the `Today`
card now shows bounded saved-workout evidence immediately instead of an
unhelpful generic `Workout learning` tile. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-fast-workout-today-card-device-verify/`
built, installed, launched, reconnected to `ADIDSHAFT'S WHO`, and logged
`today_usability ... workout_value=strength ... workout_peak_hr=120
workout_threshold_hr=121 workout_stream_coverage_percent=87
workout_duration_s=3030`. This makes the app more usable after a real gym
session: it reports the saved strength-like/near-miss signal and explains that
it is not counted because the evidence is still
`stream_gaps_and_hr_below_threshold`. Gate E remains learning.

**App usability checkpoint 2026-06-15, battery + RR package:** the `Today`
card now surfaces strap battery, strict saved-RR package readiness, and baseline
maturity on the first screen. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-today-battery-rr-package-device-verify/`
built twice, installed, launched, reconnected to `ADIDSHAFT'S WHO`, and logged
`rr_package_ready=1 rr_package_raw=368 rr_package_kept=361
rr_package_conf=98 rr_package_gap_s=1.8 rr_package_rmssd=32.7`. A longer
follow-up run logged live `battery level=40 source=2A19` and
`today_usability_update reason=battery battery_level=40`. The RR package is
shown only as reference-ready; Gate B remains `reference_pending`, Recovery
remains `learning`, and no HRV/recovery metric is promoted without external
reference validation.

**Gate G usable-local checkpoint 2026-06-15:** after the single-device
execution router selected Gate G as the next useful local path, Atria was
re-launched on the cabled physical iPhone in
`docs/evidence/gate-g/20260615T-usable-healthkit-backup-reference-nobuild-device-verify/`.
The full physical build/install path was blocked by iPhone development services
requiring an unlock, so this evidence is labeled as a `--no-build` launch of the
already installed current Atria bundle; a separate generic iOS build completed
green immediately afterward. The on-device run verified the practical local
platform loop: backup wrote and verified
`sessions=301 rr_samples=24573 digest_match=1`, the pulled backup JSON is valid,
HealthKit saved `665` incremental Atria HR samples, and HealthKit readback
reconciled the store with `readback_atria_hr_samples=50260`,
`expected_total_atria_hr_samples=50260`, `readback_covers_delta=1`,
`expected_total_reconciled=1`, and `data_appears=1`. The reference audit stayed
honest: `independent_hr_samples=0`, `external_reference_ready=0`, and
`validation_reason=independent_reference_missing`, so Apple Health is not being
misused as an external HR reference. The same run connected to
`ADIDSHAFT'S WHO`, received standard `2A37` RR, and logged
`radio_low_traffic_complete=True`. Gate G is therefore locally usable for
backup and HealthKit HR readback, but still metric-gated by upstream HRV/workout
readiness; no HealthKit HRV/workout metric was promoted.

**App usability checkpoint 2026-06-15, usable platform row:** the first-screen
`Today` card now surfaces the proven local platform loop directly: Backup,
Health, and Reference. `Backup` uses a new store-level backup digest/status API,
`Health` reports Atria HR readback only, and `Reference` remains `missing` until
an independent source validates HR/HRV. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-usable-platform-today-card-device-verify/`
built green, installed via direct `devicectl` after xcodebuild destination
preflight hit an unlock/development-services warning, launched on the cabled
iPhone, connected to `ADIDSHAFT'S WHO`, and logged
`today_usability ... backup_current=1 health_readback=ok
health_data_appears=1 health_atria_hr_samples=50260
health_expected_hr_samples=50260 reference_ready=0
reference_reason=independent_reference_missing`. This moves the app closer to a
usable daily surface without promoting any gated metric.

**App usability checkpoint 2026-06-15, sleep candidate on Today:** the first
screen now shows fail-closed sleep evidence instead of hiding it behind warmed
Gate E diagnostics. The new Sleep tile uses the existing `SleepEvidenceStatus`
reducer only: `ready` still requires validated motion and non-low confidence,
while HR-only fallback windows are labeled as candidates. Physical iPhone
evidence in
`docs/evidence/app-usability/20260615T-today-sleep-candidate-device-verify/`
built green, installed, launched on the cabled iPhone, reconnected to
`ADIDSHAFT'S WHO`, and logged
`today_usability ... sleep_value=candidate sleep_ready=0
sleep_state=low_confidence sleep_blocker=sleep_motion_unvalidated_historical_stale
sleep_candidates=2 sleep_fallback=1
sleep_fallback_source=hr_only_fragmented_sleep sleep_fallback_duration_s=10545
sleep_fallback_span_s=13706 sleep_motion_validated=0`. This makes the overnight
wear session visible and useful, but Gate E remains learning until sleep motion
is validated or another approved motion/fallback path is proven.

**App usability checkpoint 2026-06-15, Today settled-state diagnostics:** the
Today card now emits a second, settled diagnostic when BLE connects or live HR
first appears, plus a waiting diagnostic if the strap is still not connected
after the first launch window. This prevents the initial pre-connect snapshot
from being the only first-screen evidence. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-today-connection-settled-device-verify/`
built green, installed, launched, connected to `ADIDSHAFT'S WHO`, received real
standard `2A37` RR, and logged
`today_usability_update reason=connected connected=1 ... next_action=Strength_signal_saved...`
followed by `today_usability_update reason=live_hr connected=1 hr=67`.
The same run kept Gate B `reference_pending`, Gate E `learning`, Gate G
`metric_gated`, and low-radio mode ready; no metric gate was promoted.

**App usability checkpoint 2026-06-15, daily evidence card:** the Today screen
now has a bounded `Detected locally` card that surfaces today's saved minutes,
RR count, sleep/activity candidates, and the saved strength-like signal without
counting it as a workout. It uses recent saved sessions on launch instead of a
full historical replay, keeping large local stores on the fast path. Physical
iPhone evidence in
`docs/evidence/app-usability/20260615T-daily-evidence-card-device-verify-4/`
built green, installed, launched, reconnected to `ADIDSHAFT'S WHO`, received
standard `2A37` RR, and logged
`daily_evidence_ui ... activity_candidates=1 workout_signal=1
workout_diagnosis=fragmented_stream_and_below_threshold diagnostic_only=1`.
Gate B stayed `reference_pending`, Gate E stayed `learning`, Gate G stayed
`metric_gated`; no metric gate was promoted.

**App usability checkpoint 2026-06-15, collection reliability card:** the first
screen now surfaces long-wear/checkpoint protection, active-journal freshness,
RR presence, and watchdog recovery state from bounded local diagnostics.
Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-collection-reliability-card-device-verify/`
built green, installed, launched, reconnected to `ADIDSHAFT'S WHO`, received
standard `2A37` RR, and logged
`collection_reliability_ui ... long_wear=1 checkpoint_armed=1 ... fail_closed=1`.
The refresh run restored a fresh journal and logged
`journal_present=1 journal_fresh=1 journal_rr_values=2
journal_rr_coverage_3s_percent=100 rr_present=1`; later it exposed
`rr_presence_status=hr_only` with `hrv_policy=learning_only` still enforced in
the watchdog logs. This makes unattended collection status visible and
debuggable with the single strap, but does not promote Gate B/E/G.

**Gate G update 2026-06-15 cached platform evidence in bounded status:** the
large-store fast Gate Status path now uses cached HealthKit readback,
widget/app-group, and backup diagnostics instead of marking Gate G as skipped
with `healthkit_status_skipped_bounded_audit`. Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-bounded-gate-g-cached-platform-device-verify/`
built green, installed, launched, wrote and verified a current backup
(`sessions=308`, `digest_match=1`), exported/read back Atria HR in HealthKit
with `expected_total_reconciled=1` and `data_appears=1`, verified widget/shared
app-group readiness, delivered the diagnostic notification, and kept
`standard_hr_only` low-radio mode ready. Gate G now logs `platform_ready=1` and
`status=metric_gated` with only
`healthkit_hrv_reference_pending+healthkit_workout_learning` as metric
blockers. The execution router logs `local_blocked=none`, so the next useful
local work is metric validation and usability, not another platform replay. No
HRV, workout, or HealthKit metric was promoted.

**Gate E/G usability checkpoint 2026-06-15 user-confirmed workout export:**
Atria now has a user-confirmed path for the best saved local activity candidate.
The UI exposes `Confirm Activity`, and the debug harness exposes
`--confirm-best-workout-candidate`; both store a separate
`UserConfirmedWorkout` without counting it as an automatic Gate E workout. A
focused physical iPhone run in
`docs/evidence/gate-e/20260615T-user-confirmed-workout-healthkit-device-verify/`
built green, installed, launched on the cabled phone, confirmed one
long-wear/strength-like candidate (`duration_s=47889`, `observed_s=17744`,
`samples=19085`, `peak_hr=122`,
`confidence=user_confirmed_near_miss`), wrote a local backup, and exported a
HealthKit workout with `atria_workout_source=user_confirmed` and
`auto_gate_e_unchanged=1`. HealthKit saved/read back `workouts=1`,
`hr_samples=70`, and `expected_total_reconciled=1`; the follow-up status run
showed `healthkit_workouts=1` and Gate G `platform_ready=1`. This makes workouts
usable for the single-device setup when the user confirms them, but Gate E still
remains `learning` until sustained automatic workout detection passes without
manual confirmation. Gate G's remaining metric blocker is HRV reference
validation.

**Gate E usability checkpoint 2026-06-15 user-confirmed sleep candidate:**
Atria now has a user-confirmed path for the best saved local sleep candidate.
The UI exposes `Confirm Sleep`, and the debug harness exposes
`--confirm-best-sleep-candidate`; both store a separate `UserConfirmedSleep`
without counting it as automatic Gate E sleep. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-user-confirmed-sleep-device-verify/` built
green, installed, launched on the cabled phone, and confirmed an HR-only
interrupted overnight aggregate from `2026-06-14T01:00:21Z` to
`2026-06-14T04:48:46Z` (`duration_s=10545`, `span_s=13706`, `sessions=2`,
`samples=6249`, `avg_hr=60`, `peak_hr=102`,
`confidence=user_confirmed_hr_only`). The log explicitly kept
`motion_validated=0`, `metric_promotions=0`, `auto_gate_e_unchanged=1`,
`healthkit_source=none`, and `local_only=1`. A follow-up launch reported
`sleep_confirm status=already_confirmed` and
`daily_evidence_ui ... confirmed_sleeps=1`. This makes sleep evidence usable
for the single-device setup, but automatic sleep remains learning/partial until
motion evidence is validated.

**Gate G usability checkpoint 2026-06-15 user-confirmed sleep HealthKit export:**
Atria now has the local code path to export `UserConfirmedSleep` as HealthKit
Sleep Analysis with `atria_sleep_source=user_confirmed`,
`auto_gate_e_unchanged=1`, and `metric_promotions=0`; Gate G evidence includes
`healthkit_sleeps=1`, and the harness waits for
`healthkit_sleep_export_verify` when a confirmed sleep export is requested.
Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-user-confirmed-sleep-healthkit-device-verify/`
built green, installed, launched on the cabled phone, and confirmed the local
sleep item, but the HealthKit write stopped at
`healthkit_export status=authorization_pending ... sleeps=1 read_sleep=1`.
The summary intentionally failed with `healthkit_export_verify_complete=False`
and `healthkit_sleep_export_verify_complete=False`; no HealthKit sleep sample
was written/read back, and Gate G did not pass. This path is ready for the next
device run after Apple Health Sleep Analysis permission is approved on the
iPhone.

**Gate G usability checkpoint 2026-06-15 HealthKit partial export fallback:**
Atria now splits HealthKit export by authorized sample type, so a pending Sleep
Analysis permission cannot block already authorized heart-rate export. Physical
iPhone evidence in
`docs/evidence/gate-g/20260615T-healthkit-partial-sleep-defer-device-verify/`
built green, installed, launched on the cabled phone, and ran the same
confirmed-sleep + HealthKit export path. The app logged
`healthkit_sleep_export status=permission_required ... authorization=not_determined`,
then continued with `healthkit_export status=authorization_cached ... hr_samples=157 ...
sleeps=0`, saved the HR delta, and read Apple Health back with
`healthkit_export_verify status=ok ... expected_delta_hr_samples=157 ...
expected_total_reconciled=1 ... data_appears=1`. The harness finished with
`healthkit_export_verify_complete=True` and
`healthkit_sleep_export_deferred_complete=True`; no sleep sample was written,
no metric was promoted, and Gate G remains `metric_gated` until HRV reference
validation and Sleep Analysis permission are available.

**Gate C/G usability checkpoint 2026-06-15 recovery guidance explainability:**
Daily guidance now consumes the full Recovery estimate rather than only a
nullable percent, so the card and `WHOOPDBG guidance_decision` explain why the
target is unavailable when Recovery is still learning. Physical iPhone evidence
in
`docs/evidence/gate-c/20260615T-recovery-guidance-explainability-device-verify/`
built green, installed, launched on the cabled phone, and logged
`guidance_decision recovery=learning recovery_confidence=learning
target=learning state=learning reason=recovery_learning_not_high
recovery_detail=learning__need_validated_HRV`. Gate C stayed `learning` with
`validated_hrv_baseline=0/7`, so no Recovery metric was promoted. The same
checkpoint fixed a stale in-app readiness contradiction: after user-confirmed
HealthKit workout export, Gate G's UI row now matches Gate Status with
`platform_ready_metric_blockers:healthkit_hrv_reference_pending`, not a workout
blocker.

**Gate D usability checkpoint 2026-06-15 HRmax calibration hint:** the Profile
card now shows the highest real HR Atria has observed from saved/live samples
and only permits a user-confirmed measured-HRmax raise when that observed peak
exceeds the current measured HRmax. It never lowers HRmax from submax data and
never changes the profile automatically. Physical iPhone evidence in
`docs/evidence/gate-d/20260615T-hrmax-calibration-hint-device-verify/` built
green, installed, launched on the cabled phone, and logged
`hrmax_calibration_ui ... observed_peak=122 saved_peak=122 live_peak=82
measured_max_hr=190 active_max_hr=189 source=ageEstimate can_raise_measured=0
suggestion=keep_profile_no_auto_lower auto_change=0
user_confirmation_required=1`. Gate D remained `partial`: the same run logged
`strain_validation ready=0` with blockers
`stream_coverage_below_75_percent+missing_high_zone_exposure+max_hrr_below_85_percent+external_hr_reference_missing`.

**Gate E usability checkpoint 2026-06-15 strict sleep candidate split:** Daily
rollups and Local Status now fail closed between validated sleep days and
low-confidence HR-only sleep candidates. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-strict-daily-rollup-sleep-candidates-device-verify/`
built green, installed, launched on the cabled phone, and logged
`daily_rollup_summary ... sleep_ready_days=0 sleep_candidate_days=2
workout_days=0`. The two overnight candidates remained `sleep_ready=0` with
`sleep_gate_strict=1`, while the Today card reported `sleep_value=candidate`,
`sleep_ready=0`, and
`sleep_blocker=sleep_motion_unvalidated_historical_stale`. Gate E stayed
`learning`; this improves single-device usability without promoting HR-only
sleep into a completed automatic sleep metric.

**Gate E usability checkpoint 2026-06-15 confirmed workout rollup split:**
Daily rollups and Local Status now fail closed between strict automatic workout
days and user-confirmed workout evidence. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-confirmed-workout-rollup-device-verify/` built
green, installed, launched on the cabled phone, and logged
`daily_rollup_summary ... workout_days=0 confirmed_workout_days=1
confirmed_workouts=1`. The June 14 row kept `workouts=0
confirmed_workouts=1 workout_gate_strict=1`, so manual usefulness no longer
hides the fact that automatic workout detection is still learning. The same
run logged `broken_sleep_summary candidates=2`; adidshaft's reported short nap
did not create a new sleep candidate under the current strict
duration/overnight detector.

**Gate E usability checkpoint 2026-06-15 rest/nap candidate diagnostics:**
Atria now surfaces short low-HR saved chunks as `Rest candidate` diagnostics
instead of dropping them from the local evidence model. These candidates are
explicitly `rest_diagnostic_only=1`; they do not count as sleep, do not feed
HRV/Recovery, and do not promote Gate E. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-rest-nap-candidate-device-verify/` built green,
installed, launched on the cabled phone, and logged
`daily_rollup_summary ... rest_candidate_days=1 rest_candidates=1 ...
sleep_ready_days=0 sleep_candidate_days=2`. The detected rest candidate was on
June 14, while the same run's current-day evidence stayed
`rest_candidates=0`, so adidshaft's reported short nap did not produce a saved
current-day low-HR rest chunk under this detector.

**Gate G checkpoint 2026-06-15 confirmed sleep HealthKit permission recheck:**
After the user reported Sleep permission changes, the same confirmed-sleep
HealthKit export path was rebuilt, installed, and launched on adidshaft's cabled
physical iPhone in
`docs/evidence/gate-g/20260615T-healthkit-sleep-permission-retry-device-verify/`.
The app confirmed the existing local sleep item after the user reported granting
Apple Health write access, but Sleep Analysis authorization still came back
`not_determined`:
`healthkit_sleep_export status=permission_required sleeps=1
authorization=not_determined`. No sleep sample was written or read back, and
the harness correctly recorded `healthkit_sleep_export_deferred_complete=True`
instead of a sleep-export pass. The authorized HR path continued independently:
`healthkit_export status=saved ... hr_samples=489 ... sleeps=0`, followed by
`healthkit_export_verify status=ok ... expected_total_reconciled=1 ...
data_appears=1`. Gate G remains `metric_gated` by
`healthkit_hrv_reference_pending`; Sleep Analysis export remains permission
blocked until iOS grants that sample type.

**Gate G checkpoint 2026-06-15 Sleep Analysis authorization request fix:**
`docs/evidence/gate-g/20260615T-healthkit-sleep-auth-request-devicectl-nobuild/`
verifies the corrected authorization path on adidshaft's physical iPhone. The
previous exporter treated Sleep Analysis `not_determined` like a denied state
and removed confirmed sleeps from the writable plan before HealthKit could show
the permission sheet. Atria now keeps the confirmed sleep in the writable plan,
logs `healthkit_sleep_export status=authorization_required sleeps=1
authorization=not_determined action=request_health_sleep_analysis`, and calls
HealthKit with `healthkit_export status=authorization_requested ... sleeps=1
read_sleep=1`. The same cabled-device run reached
`healthkit_export status=authorization_pending ... action=approve_health_permissions_on_device`,
and the harness reports `healthkit_export_authorization_pending_complete=True`
instead of failing the verifier. This is a real-device authorization unblock,
not a sleep-write pass: no Sleep Analysis sample was written/read back until the
iOS permission prompt is approved. The phase also fixed the harness' identifier
split: `devicectl` uses the CoreDevice id while Xcode destinations use the
physical UDID namespace.

**App usability checkpoint 2026-06-15 manual checkpoint + Today stability:**
Atria now exposes a non-destructive `Save checkpoint` control next to
`Finish & save session`, and debug launches can fire the same path with
`--whoop-manual-checkpoint-after N`. This preserves the current live session as
a saved checkpoint without resetting long-wear collection, so short rest, nap,
and activity slices can be captured immediately instead of waiting for a timer
or ending the session. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-manual-checkpoint-device-verify/`
includes the first failed launch, its copied crash report
`Atria-2026-06-15-173719.ips`, and the follow-up fix. The failure was a
SwiftUI/iOS 27 stack-guard crash while building the large Today card; the card
was hardened by moving metric tiles into data-driven rows, then rebuilt,
installed, and relaunched on the same cabled iPhone. The successful run logged
`manual_checkpoint status=saved samples=11 rr_samples=0 duration_s=10 ...
reset_live_session=0`, `session_store_save status=ok op=checkpoint`, and
`session_backup_auto status=ok reason=session-checkpoint`; collection reliability
then showed `checkpoint_last_status=saved_manual` with a fresh journal. No Gate
E sleep/workout metric was promoted by this checkpoint; it is a usability and
data-preservation improvement.

**App usability checkpoint 2026-06-15 manual checkpoint harness wiring:**
`live_device_debug.sh --manual-checkpoint-after N` now forwards the existing
app debug trigger through the standard cabled-device harness, so future manual
checkpoint checks do not need raw `devicectl` launch commands. Physical iPhone
evidence in
`docs/evidence/app-usability/20260615T-manual-checkpoint-harness-device-verify/`
built green, installed, launched, and logged `HARNESS_LAUNCH_ARGS ...
--whoop-manual-checkpoint-after 15` / `45`, then
`manual_checkpoint schedule delay_s=... source=launch_arg`. The same evidence
also records the fail-closed case from the current strap state: Atria was
`connected=0`, kept fresh-scanning, and reported
`checkpoint_last_status=skipped_manual_insufficient_samples` rather than saving
an empty checkpoint or promoting any metric. This is a tooling/usability
checkpoint; Gate B, E, and G statuses are unchanged.

**App usability checkpoint 2026-06-15 post-harness long-wear relaunch:**
After the manual-checkpoint harness stopped its console session, Atria was
relaunched in low-radio standard-HR-only long-wear mode with `--leave-running`
so local collection could continue unattended. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-leave-running-after-harness/` matched
the strap, connected, parsed real standard `2A37` R-R intervals
(`standardHR ... rrnum=2`, `rr_quality source=2a37 fraction=1.000`), and saved
the active journal up to `samples=20 rr_values=24 duration_s=18` before the
harness relaunched Atria headless with 60-second checkpoints and 15-minute
autosaves. The live workout detector correctly stayed `learning` because HR
was below the workout band. This proves continuity and data preservation after
tooling runs; it does not pass Gate B's 5-minute/reference requirement.

**Gate B checkpoint 2026-06-15 standard 2A37 5-minute capture after reconnect:**
`live_device_debug.sh --pull-capture DIR` now waits for a real
`WHOOPDBG capture_file` before treating capture pull work as complete; the
first attempt in
`docs/evidence/gate-b/20260615T-standard-2a37-5min-capture-after-reconnect/`
proved the old harness bug by interrupting Atria immediately after launch.
After the guard, the same physical-iPhone run built green, installed, launched,
and ran for the full 420-second evidence window in `standard_hr_only` strict
live RR mode. It did not pass Gate B: the only logged standard heart-rate
payloads were HR-only (`standard_2a37_frames=5`,
`standard_2a37_rr_frames=0`, `last_standard_2a37_rrnum=0`), auto-capture could
only start by timeout, no `capture_summary` or capture CSV was produced, and
the app repeatedly logged HR/RR watchdog reconnects with missing 2A37 samples.
Atria saved the HR-only chunk (`samples=30 duration_s=42`) and kept
HRV/Recovery learning/reference-pending. This rules out a harness/pull bug for
the current failed capture; the active blocker is live 2A37 RR availability and
BLE notification continuity in this run, not HRV computation.

**Gate B/E durability update 2026-06-15 missing 2A37 recovery:** the failed
5-minute capture also exposed a second app-side stall: Atria could be connected
while the cached standard Heart Rate Measurement characteristic was missing.
That state previously only logged `wait_missing_2a37_char`, which could leave
the app connected but unable to receive `2A37` HR/RR. The HR-continuity and
RR-presence watchdogs now actively rediscover the Heart Rate service when this
happens; if the characteristic is still missing after the watchdog timeout and
raw HR is stale, Atria saves the active journal and fresh-scan reconnects.
Physical iPhone evidence in
`docs/evidence/gate-b/20260615T-missing-2a37-recovery-device-verify/` built
green via the generic iOS path, installed with `devicectl`, launched on the
cabled phone, connected to `ADIDSHAFT'S WHO`, enabled `2A37`, then used the
debug-only `--force-missing-2a37-after 18` trigger after discovery. The on-device
log proved the intended branch: `missing_2a37_debug status=forced
had_characteristic=1`, followed by `hr_continuity_watchdog
status=forced_missing_2a37 ... action=rediscover_2a37_service`, then
`notifyState ch=2A37 notifying=1`. The run's actual `2A37` payloads were HR-only
(`standard_2a37_frames=5`, `standard_2a37_rr_frames=0`), so this is a
continuity recovery fix only. Gate B remains not passed: no clean 5-minute RR
window and no independent RR/IBI RMSSD reference comparison.

**Gate status tooling update 2026-06-15 activity diagnostic cap:** current-store
diagnostics no longer flood the launch log with every activity candidate.
`--whoop-log-activity-detections` ranks detections by confidence, kind,
duration, and peak HR, emits the top 12, and reports the suppressed count plus
kind totals. Physical iPhone evidence in
`docs/evidence/gate-status/20260615T-activity-diagnostics-cap-device-verify/`
logged `activity_detect_summary sessions=327 detections=60 emitted=12
suppressed=48 workouts=0 activity_candidates=58 sleep_candidates=1
rest_candidates=1`, then left Atria running in low-radio long-wear mode. The
same checkpoint fixed a harness completion bug: delayed `--log-gate-status`
runs no longer stop early just because a post-gate side effect completed, and a
focused gate-status run reached all rows. The failed combined
activity+daily+trend+gate audit is intentionally preserved as a constraint:
large-store diagnostics must be split into focused launches instead of claiming
one heavyweight launch is reliable. Gate statuses are unchanged.

**Gate E usability checkpoint 2026-06-15 short rest review:** with only one
WHOOP strap and no external reference device available, the local execution
track now prioritizes honest usefulness over retrying reference-gated exits.
Atria now surfaces quiet HR-only rest/nap review chunks down to two minutes,
but only when average, p95, and peak HR remain below the workout band. This
addresses the observed current-day nap/checkpoint gap: the saved chunks were
real but shorter than the old 10-minute detector floor. The branch is
diagnostic-only and cannot pass sleep/workout gates, write HealthKit sleep, or
change Recovery/HRV. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-short-rest-review-device-verify/` built green,
installed, launched, and logged `activity_detect_summary sessions=331
detections=104 emitted=12 suppressed=92 workouts=0 activity_candidates=58
sleep_candidates=1 rest_candidates=45`. A focused daily-rollup launch then
logged `day=2026-06-15 ... rest_candidates=1 ... workout_gate_strict=1
sleep_gate_strict=1 rest_diagnostic_only=1`. The full clinical Gate B/D exits
remain external-reference blocked; the single-device product track should keep
those gates explicitly reference-pending while polishing local collection,
explainability, trends, backups, HealthKit readback, and confidence states.

**App usability checkpoint 2026-06-15 Today rest consistency:** the short-rest
detector was working in daily rollups, but the Today card could still show
`rest_candidates=0` because it capped detection input to the newest 40 recent
sessions. The Today summary now evaluates all same-day saved sessions and only
caps older recent history. Physical iPhone evidence in
`docs/evidence/app-usability/20260615T-today-rest-summary-device-verify/`
built green, installed, launched, and logged `daily_evidence_ui ...
rest_candidates=2 ... top_kind=Rest candidate ... top_duration_s=147 ...
top_reason=Quiet HR-only rest/nap review; below workout band; not counted as
sleep or workout ... rest_diagnostic_only=1`. This is a local UI consistency
fix only; Gate E remains partial and Gate B/D remain reference-pending.

**Gate E status checkpoint 2026-06-15 confirmed local evidence:** bounded fast
Gate Status no longer reports plain `learning` when Atria already has local
user-confirmed sleep and workout records. It now logs `gate=E
status=user_confirmed` with `confirmed_workouts`, `confirmed_sleeps`,
`auto_gate_e_ready=0`, and `auto_detection_required=1`. This is deliberately not
a Gate E exit: automatic sleep/workout detection still has to be validated, but
the single-device product track can use confirmed records for local review and
HealthKit export while the detector learns from those examples. Physical iPhone
evidence in
`docs/evidence/gate-e/20260615T-user-confirmed-gate-e-status-device-verify/`
installed and launched Atria, pulled `Documents/atria-gate-status.txt`, and
captured `confirmed_workouts=1`, `confirmed_sleeps=1`,
`next_local_action=train_auto_detection_from_confirmed_sleep_and_workout`.

**Gate E training checkpoint 2026-06-15 confirmed-vs-auto blockers:** Gate
Status now turns the confirmed sleep/workout examples into focused training
diagnostics instead of another broad replay pass. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-confirmed-vs-auto-training-device-verify/`
built green, installed, launched, and pulled `Documents/atria-gate-status.txt`
with two new `WHOOPDBG_gate_e_training` rows. The confirmed workout is a real
near-miss but not an automatic workout: `auto_ready=0`,
`primary_blocker=stream_gaps`, `coverage_percent=38`, `peak_hr=122`,
`p95_hr=90`, `threshold_hr=121`, `elevated_s=3/1200`, and
`longest_bout_s=3/480`. The confirmed sleep overlaps the best aggregate sleep
candidate, but automatic sleep is still blocked by HR-only fragmented evidence,
below-strict 3-hour low-HR total, stale historical gravity, and
`motion_validated=0`. This does not pass Gate E. It makes the next product work
decidable: keep user-confirmed records useful, train/adjust the auto detector
only from explicit blockers, and do not count sleep/workout automatically until
motion confidence or sustained-HR evidence satisfies the original contract.

**Gate E usability checkpoint 2026-06-15 Today training proof:** the same
confirmed-vs-auto evidence now appears in the Today card through a shared
`GateETrainingSummary`, so the product explains the confirmed local examples
without changing the detector. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-today-training-card-device-verify/` built
green, installed, launched, and logged `WHOOPDBG today_gate_e_training
confirmed_workout=1 workout_auto_ready=0 workout_blocker=stream_gaps
workout_stream_coverage_percent=38 workout_elevated_s=3
workout_required_elevated_s=1200 confirmed_sleep=1 sleep_auto_ready=0
sleep_motion_validated=0 auto_detection_required=1`. Gate E remains
`user_confirmed`/partial, not automatic-ready; this closes a usability gap by
making the next blocker visible on the first screen instead of only in pulled
Gate Status evidence. The bounded Gate Status router now advances the local
action to `validate_motion_or_sustained_workout_from_training_blockers` when
confirmed sleep and workout examples are already present, preventing the loop
from repeatedly pointing back at the completed training-surface work. Physical
iPhone evidence in
`docs/evidence/gate-e/20260615T-training-router-device-verify/` logged both the
Gate E action and `execution_priority ... next_local_action=validate_motion_or_sustained_workout_from_training_blockers`.

**Gate G/harness checkpoint 2026-06-15 Xcode build fallback:** the cabled iPhone
can be connected and installable through CoreDevice while Xcode's physical
destination service still rejects `id=<XCODE_DEVICE_ID>` with
`observing system notifications failed`. `live_device_debug.sh` now separates
the Xcode destination id from the `devicectl` CoreDevice id, and if the physical
Xcode build fails with that availability error it retries a signed
`generic/platform=iOS` build before installing and launching with `devicectl`.
Physical iPhone evidence in
`docs/evidence/gate-g/20260615T-xcode-build-fallback-device-verify/` logged
`HARNESS_BUILD_FALLBACK status=retry ... to_destination=generic/platform=iOS`,
then `** BUILD SUCCEEDED **`, `App installed`, and real WHOOPDBG output from
Atria. Gate Status completed with Gate G `metric_gated`, `platform_ready=1`,
`healthkit_readback_status=ok`, `backup_current=1`, battery live from `2A19`,
and the harness left Atria running in standard-HR-only long-wear mode. This is
execution hardening only; it does not promote HRV, sleep, workout, or reference
metrics.

**Gate E routing checkpoint 2026-06-15 training proof labels:** the current
single-device path cannot pretend the confirmed sleep/workout examples are
automatic detections, but it can stop looping on vague diagnostics. The shared
`GateETrainingSummary` now emits `sleep_proof`, `workout_proof`, and
`next_proof` fields used by Gate Status, Today logging, and the visible Today
training row. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-training-proof-labels-device-verify/` built via
the Xcode false-negative fallback, installed, launched, and logged
`gate=E status=user_confirmed ... auto_gate_e_ready=0`, `sleep_proof=
decode_wrist_motion_or_label_hr_only_sleep_fallback`, `workout_proof=
capture_clean_sustained_hrr50_with_stream_coverage`, and
`execution_priority ... next_local_action=sleep:decode_wrist_motion_or_label_hr_only_sleep_fallback+workout:capture_clean_sustained_hrr50_with_stream_coverage`.
This is a decision-router improvement only; Gate E exits only when the proof
labels resolve to `none` from real saved data and the original automatic
sleep/workout contract is satisfied.

**Gate E sleep fallback checkpoint 2026-06-15 labeled HR-only proof:** the sleep
proof label now resolves separately from automatic sleep readiness. If a
user-confirmed sleep substantially overlaps an HR-only overnight aggregate that
meets the broken-sleep duration/span fallback contract, Atria marks only the
fallback proof as accepted with
`sleep_fallback_policy=hr_only_sleep_fallback_labeled_confirmed_overlap`. This
does not validate motion and does not pass Gate E. Physical iPhone evidence in
`docs/evidence/gate-e/20260615T-hr-only-sleep-fallback-proof-device-verify/`
built, installed, launched, and logged `gate=E status=user_confirmed ...
auto_gate_e_ready=0`, `sleep_blocker=hr_only_fallback_labeled`,
`sleep_proof=none`, `sleep_fallback_accepted=1`, and
`next_local_action=workout:capture_clean_sustained_hrr50_with_stream_coverage`.
The remaining single-device Gate E work is therefore the sustained clean HRR50
workout proof; strap-motion sleep validation remains a future protocol/sensor
improvement.

**Gate E workout proof checkpoint 2026-06-15:** physical iPhone evidence in
`docs/evidence/gate-e/20260615T-workout-proof-status-device-verify/` tightened
the remaining workout proof. Gate Status, Today logging, and
`WHOOPDBG_gate_e_training` now emit `workout_proof_status`,
`workout_missing_coverage_percent`, `workout_missing_elevated_s`,
`workout_missing_bout_s`, and `workout_ready_if`. The current confirmed workout
remains fail-closed and explicit:
`workout_proof_status=needs_stream_coverage_75p_missing_37p`,
`workout_missing_elevated_s=1197`, `workout_missing_bout_s=477`, and
`workout_ready_if=coverage>=75+observed>=600+elevated>=1200+bout>=480+hr>=121`.
Gate E still exits only after real automatic sleep/workout evidence satisfies
the original contract; this checkpoint only removes ambiguity from the next
single-device action.

**Gate E workout proof coach checkpoint 2026-06-15:** physical iPhone evidence
in `docs/evidence/gate-e/20260615T-workout-proof-coach-device-verify/`
verified the final UI/status checklist refinement. Atria now uses one
`GateETrainingSummary` source for the visible Today checklist and all Gate E
logs: coverage, observed seconds, elevated HRR50 seconds, continuous HRR50
bout, and peak HR versus threshold. The workout readiness boolean now also
requires stream coverage `>=75%`, so the detector cannot pass on sparse data
while the proof text says coverage is missing. The device run logged
`gate_status gate=E status=user_confirmed ... auto_gate_e_ready=0`,
`workout_progress=coverage_38_of_75+observed_18109_of_600+elevated_3_of_1200+bout_3_of_480+peak_122_of_121`,
`workout_next_step=keep_phone_near_strap_until_coverage_75p`, and
`workout_ready_if=coverage>=75+observed>=600+elevated>=1200+bout>=480+hr>=121`.
The live workout row stayed `status=learning` with
`primary_blocker=stream_gaps_and_hr_below_threshold`, so this is usability plus
honesty hardening, not a Gate E pass.

**Gate B routing checkpoint 2026-06-15 current RR honesty:** physical iPhone
evidence in
`docs/evidence/gate-b/20260615T-recent-rr-routing-device-verify-2/` verified
that the phone/device path is working despite the Xcode observer false positive:
the app installed, launched, logged real `2A37` RR, and was relaunched detached
afterward. The implementation now lets one-sample active journals roll over
after long gaps and adds recent RR duration/coverage diagnostics. Atria only
treats recent current RR as locally clean when it has enough real elapsed time,
not just buffered reconnect values. The run saw a real short clean window
(`active_journal_recent_rr_duration_s=12`, coverage `100`) and then correctly
held Gate B blocked after 26-27 s gaps:
`active_journal_rr_coverage_3s_percent=17`, `active_journal_max_rr_gap_s=27.1`,
`active_journal_recent_rr_clean=0`, and
`local_blocked=B:current_rr_continuity_gap_27s_coverage_17p`. This is a
truth/routing fix only; Gate B still requires a clean 5-minute RR window and
external RR/IBI reference agreement.

**Gate B durability checkpoint 2026-06-15 staged BLE recovery:** physical
iPhone evidence in
`docs/evidence/gate-b/20260615T-staged-ble-recovery-device-verify/` replaced
the old fast long-wear reconnect cadence with staged recovery. Long wear now
schedules no-data recovery at `75s`, HR-continuity recovery at `22.5s` with
`read_or_reassert_notify`, and accepted-HR recovery at `45s`, logging
`disconnect_reconnect_policy=staged_read_reassert_then_fresh_scan`. The first
device run verified the policy and showed no new BLE disconnect during the
first observed 15.6s current-session gap; a later 29.4-32.2s notification gap
still occurred without a new disconnect, so live Gate B remains gappy. A
focused Gate Status run then verified the correct router behavior for a fresh
clean short segment: `active_journal_rr_coverage_3s_percent=100`,
`active_journal_max_rr_gap_s=2.7`, `active_journal_recent_rr_clean=1`,
`local_blocked=none`, and `next_local_gate=E`. This removes an app-created
reconnect churn path and improves usable collection, but it does not pass Gate
B; the 5-minute clean RR window plus external RR/IBI reference comparison is
still required.

**Gate H status checkpoint 2026-06-15 protocol exit split:** physical iPhone
evidence in
`docs/evidence/gate-h/20260615T-gate-h-protocol-status-device-verify/` aligns
the dashboard and Gate Status contract for historical download. Atria now treats
codec-clean stored transfer evidence as the Gate H protocol exit while keeping
metric use fail-closed. The proof run logged
`gate_readiness_ui ... H=ready[protocol_ready_metrics_fail_closed_current_usable_0_metric_usable_0]`
and `gate_status gate=H status=ready` with
`historical_download_validated=1`, `gate_h_protocol_exit_ready=1`,
`historical_archive_rows=100`, `historical_archive_raw_payload_rows=100`,
`historical_archive_undecodable_rows=0`, and
`historical_archive_gravity_validated_rows=100`. It also logged
`historical_rr_metric_ready=0`, `historical_metric_fail_closed=1`,
`historical_archive_metric_usable=0`, and
`historical_archive_current_usable=0`, so no HRV, Recovery, Sleep, Workout, or
HealthKit metric is promoted from stale/non-overlapping historical rows. Gate B
remains reference-pending; the next single-device acceleration path remains Gate
E usability and real workout/sleep evidence, not another blind historical
selector loop.

**Atria product/process checkpoint 2026-06-15:** physical iPhone evidence in
`docs/evidence/app-usability/20260615T-atria-product-name-device-verify/`
cleans up stale naming that was confusing diagnostics. The Xcode build now
reports `FULL_PRODUCT_NAME=Atria.app`, `EXECUTABLE_NAME=Atria`, and
`WRAPPER_NAME=Atria.app`; the device install reported
`installationURL=.../Atria.app/`; and WHOOPDBG console rows were emitted by
`Atria[...]`. A stale legacy `Whoop.app/Whoop` process and old widget extension
were terminated after the install, leaving the detached process list with only
`/Atria.app/Atria`. The updated non-disruptive pull reports
`process_status=running` and `process_name_status=atria`, while the active
journal remains fresh with real RR present. This improves future evidence
collection and does not promote any metric.

**Gate E decision checkpoint 2026-06-15 current store:** non-disruptive pull
evidence in
`docs/evidence/gate-e/20260615T160055Z-current-store-workout-decision/`
prevents another detector-loosening loop. The current store has `400` sessions,
but offline replay with the app profile (`rest_hr=52`, `max_hr=190`) found
`ready=0`, `aggregate_ready=0`, `window_ready=0`, and
`aggregate_window_ready=0`. The strongest HRR50 candidate had good coverage
(`85%`) and peak `122` against threshold `121`, but only `3s` above threshold
and `3s` longest bout versus the required `1200s` elevated and `480s` bout.
Diagnostic sensitivity at HRR35/40/45/50 also produced zero ready candidates.
Therefore Gate E remains user-confirmed/partial, the strength signal stays
diagnostic-only, and the next usable path is a genuinely sustained HRR workout
or validated profile/reference update, not fake threshold relaxation.

**App usability checkpoint 2026-06-15 collection health:** physical iPhone
evidence in
`docs/evidence/app-usability/20260615T-collection-health-device-verify/`
adds a compact `WHOOPDBG collection_health` verifier and harness flag. This
handles the recurring Xcode
`observing system notifications failed Development services need to be enabled`
false negative: when `devicectl` reports the phone wired, paired, booted, and
Developer Mode enabled, the harness labels the warning
`xcode_notification_observe_false_negative`, builds for `generic/platform=iOS`,
installs with `devicectl`, and launches on the physical iPhone. The proof run
logged `collection_health_complete=True` and
`status=learning blocker=active_journal_missing ... metric_promotions=0`.
That is intentionally fail-closed: saved sessions and diagnostics existed, but
the fresh active journal was absent at launch, so no Gate B/Gate E metric was
promoted. Atria was relaunched detached afterward and confirmed running as
`/Atria.app/Atria`.

**App usability checkpoint 2026-06-15 first-sample journal:** physical iPhone
evidence in
`docs/evidence/app-usability/20260615T-active-journal-first-sample-device-verify/`
removes the launch-order blind spot from the previous checkpoint. Long-wear
mode now persists the active journal on the first real accepted `2A37` HR sample
with `reason=first_accepted_hr`, and the harness can delay
`WHOOPDBG collection_health` with `--log-collection-health-after N` so it
measures post-BLE collection state. The proof run logged
`active_session_journal status=saved reason=first_accepted_hr samples=1
rr_values=0`, then `collection_health phase=delayed status=ready blocker=none
active_journal_present=1 active_journal_fresh=1 active_journal_samples=10`.
The pulled journal had `14` real HR samples, `0` RR values, and a fresh
post-run age of `4s`; Atria was relaunched detached and confirmed running as
`/Atria.app/Atria`. This improves collection reliability and diagnostics only:
Gate B remains learning/reference-pending because RR was absent, and Gate E
remains auto-detection-pending.

**Gate Status checkpoint 2026-06-15 live settle:** physical iPhone evidence in
`docs/evidence/gate-status/20260615T-live-settled-gate-status-device-verify/`
aligns persisted Gate Status with live collection. If Gate Status is requested
with standard-HR/long-wear launch arguments and no explicit delay, Atria now
self-schedules an 18s settle delay before logging and persisting status rows.
The proof run logged `gate_status schedule delay_s=18.0
reason=live_collection_settle`, then completed Gate Status with Gate B evidence
`active_journal_present=1`, `active_journal_fresh=1`,
`active_journal_samples=1`, `active_journal_rr_values=0`,
`active_journal_recent_rr_clean=0`, and `reference_validated=0`. The final
state pull found a fresh active journal with `6` real HR samples and `0` RR
values. This fixes stale launch-time `active_journal_missing` snapshots without
promoting HRV, Recovery, Sleep, Workout, or HealthKit metrics from insufficient
data.

**App usability checkpoint 2026-06-15 current collection source:** physical
iPhone evidence in
`docs/evidence/app-usability/20260615T-current-collection-saved-tail-device-verify-2/`
keeps collection diagnostics from misclassifying a just-saved long-wear tail as
missing live data. The proof run again showed the known Xcode observer false
positive while `devicectl` reported the phone wired, paired, booted, and
Developer Mode enabled, so the harness used the generic iOS build plus
`devicectl` install/launch path. Atria now reports recent saved tails inside
the checkpoint window as `current_collection_source=saved_session_tail`, then
switches to `active_journal` after a fresh accepted `2A37` HR sample. Verified
rows included `collection_ready=1`, `collection_source=saved_session_tail`,
`collection_age_s=275`, and later `current_collection_ready=1`,
`current_collection_source=active_journal`, with
`current_collection_metric_promotions=0`. Gate B remained
`reference_pending` because the current standard-HR frames carried HR only
(`rrnum=0`), Gate E remained user-confirmed/auto-pending, Gate G remained
platform-ready but HRV metric-gated, and Gate H remained protocol-ready with
metrics fail-closed.

**Gate B checkpoint 2026-06-15 non-disruptive RR segment auditor:** physical
iPhone evidence in
`docs/evidence/gate-b/20260615T-nondisruptive-rr-segment-auditor-device-verify/`
narrows the current Gate B blocker. `pull_atria_state.sh` now copies the live
Atria container without stopping the app and computes RR quality for the active
journal, latest saved tail, best whole saved RR session, and best contiguous
saved RR segment. The best whole saved RR session remains fail-closed because
it contains a `3028.5s` gap, but the best contiguous saved segment from
`gate-b-2a37-reset-keep-recording` is locally clean:
`raw_beats=372`, `duration_s=309.0`, `corrected_beats=337`,
`kept_percent=91`, `max_gap_s=2.8`, and
`best_saved_rr_segment_gate_b_local_ready=1`. This does not pass clinical Gate
B because the independent RR/IBI RMSSD comparison is still missing; it does
prove that the local saved-history blocker is no longer "no clean 5-minute RR
window." The remaining Gate B blocker is external reference validation, while
all metric outputs stay learning/reference-gated until that proof exists.

**Gate B checkpoint 2026-06-15 bounded Gate Status RR replay:** physical iPhone
evidence in
`docs/evidence/gate-b/20260615T-bounded-rr-replay-gate-status-device-verify/`
brings the in-app fast Gate Status row into alignment with the segment auditor.
The bounded large-store path now runs the exhaustive RR-only 300s replay but
continues to skip expensive workout/deep replay. The device run logged
`bounded_rr_replay_done mode=fast ready=1 label=gate-b-300s-live-rr raw=368
kept=361 conf=98 max_gap_s=1.8 reason=ready`; Gate B then persisted
`saved_rr_ready=1`, `saved_rr_best_rmssd=32.7`, and
`rr_replay=computed_exhaustive_rr_only`. The status remains
`reference_pending` with `external_rr_reference_required=1` and
`reference_validated=0`, so no HRV/Recovery/HealthKit HRV metric is promoted.
The current Gate B blocker is now cleanly narrowed to independent reference
validation.

**Gate B checkpoint 2026-06-15 Today HRV reference-pending display:** physical
iPhone evidence in
`docs/evidence/gate-b/20260615T-today-hrv-display-reference-pending-device-verify/`
closes the UI honesty gap after the clean saved RR package was found. The Today
HRV tile and larger HRV card now show pending/reference-needed when saved RR is
locally ready, instead of implying Atria is still learning the RR window. The
device run logged `WHOOPDBG hrv_display state=reference_pending
rr_package_ready=1 rr_package_raw=368 rr_package_kept=361 rr_package_conf=98
rr_package_gap_s=1.8 rr_package_rmssd=32.7
reason=external_rr_reference_required surface=today`, then Gate B persisted
`saved_rr_ready=1`, `saved_rr_best_rmssd=32.7`,
`external_rr_reference_required=1`, and `reference_validated=0`. This advances
the product toward usable, honest feedback without passing clinical Gate B or
exporting HRV to HealthKit.

**Gate F checkpoint 2026-06-15 bounded local trends:** physical iPhone evidence
in `docs/evidence/gate-f/20260615T-bounded-local-trends-device-verify/`
keeps the fast large-store Gate Status path from masking usable local trend
progress. The bounded path now computes local 7/30/90-day trend summaries and
sets Gate F to `partial` when non-HRV local trend data exists, while preserving
the full gate blockers. The device run logged `WHOOPDBG trend_fast_local
windows=3 local_windows=3 rhr_points=3 strain_points=3 recovery_points=0
hrv_points=0 trend90_confidence=learning trend90_coverage_days=3
trend90_required_coverage_days=63 trend90_coverage_percent=3
hrv_reference_gated=1 status=partial`, and Gate F persisted
`trend_replay=fast_local_summary`, `local_non_hrv_trends_ready=1`,
`trend90_rhr_points=1`, `trend90_strain_points=1`, and
`trend_blockers=coverage_below_70pct+hrv_reference_pending+recovery_points_missing+hrv_points_missing`.
This is a usability/status accuracy checkpoint: Gate F is not ready until more
real history exists and the HRV/Recovery reference gates are cleared.

**Gate E checkpoint 2026-06-15 workout proof intensity routing:** physical
iPhone evidence in
`docs/evidence/gate-e/20260615T-workout-proof-intensity-routing-final-device-verify/`
keeps the confirmed-workout training proof from over-focusing on Bluetooth
coverage when the saved workout also shows missing received-HR intensity. The
strict HRR50 workout detector is unchanged. The Today proof, Gate Status, and
execution priority now report `workout_blocker=stream_gaps+intensity_unvalidated`,
`workout_proof=capture_clean_hrr50_or_validate_received_hr`,
`workout_proof_status=needs_stream_coverage_75p_missing_37p+needs_sustained_hrr50_1197s`,
and `workout_next_step=keep_phone_near_strap_and_validate_received_hr_intensity`.
Gate E remains `user_confirmed`/auto-pending (`auto_gate_e_ready=0`,
`auto_detection_required=1`) until a real automatic workout passes the
unchanged coverage, duration, sustained HRR50, and bout contract.

**App usability checkpoint 2026-06-15 Today next-action alignment:** physical
iPhone evidence in
`docs/evidence/app-usability/20260615T-today-next-action-gate-e-alignment-device-verify/`
aligns the Today action row with the Gate E training proof. The first screen now
uses the same source-of-truth routing as Gate Status and logs
`next_action=Keep phone near strap and validate received HR intensity before counting workouts.`
on initial render, reconnect, and first live-HR update. This prevents the app
from over-simplifying the current workout blocker to connectivity only while the
saved gym evidence also lacks sustained received-HR intensity. No metric or gate
was promoted; Gate E remains auto-pending.

**Execution checkpoint 2026-06-15 nonzero Xcode observer fallback:** physical
iPhone evidence in
`docs/evidence/gate-status/20260615T-harness-nonzero-xcode-observer-fallback-device-verify/`
hardens the real-device loop against the known
`observing system notifications failed` / "Development services" false
negative. `live_device_debug.sh` now handles the case where
`xcodebuild -showdestinations` exits nonzero with that observer message: it
checks `devicectl device info details`, requires paired/wired/booted/Developer
Mode enabled, then falls back to `generic/platform=iOS` while continuing to
install and launch through `devicectl`. The shimmed proof logged
`HARNESS_XCODE_DESTINATION_WARNING suppressed=1 ... showdestinations_status=70`,
then built, installed, launched, emitted Gate Status rows, pulled sessions, and
left Atria running detached on the physical iPhone. This removes a workflow
false stop; no metric or gate was promoted.

**Execution checkpoint 2026-06-15 saved-RR-ready routing:** physical iPhone
evidence in
`docs/evidence/gate-status/20260615T-execution-priority-saved-rr-ready-routing-device-verify/`
prevents the execution router from looping on transient active-journal RR gaps
after the saved RR replay has already found a clean 5-minute package. The
device run showed the exact mixed state: Gate B stayed honest with
`saved_rr_ready=1`, `saved_rr_best_raw=368`, `saved_rr_best_kept=361`,
`saved_rr_best_conf=98`, `saved_rr_best_gap_s=1.8`, and
`saved_rr_best_rmssd=32.7`, while also exposing current live quality
(`active_journal_max_rr_gap_s=55.5`,
`active_journal_rr_coverage_3s_percent=15`, and
`active_journal_recent_rr_clean=1`). The router now logs
`next_action=provide_external_rr_reference_for_ready_rr_window`,
`next_local_gate=E`,
`next_local_action=workout:capture_clean_hrr50_or_validate_received_hr`, and
`local_blocked=none`. Gate B remains `reference_pending`; this is an execution
focus fix so local work continues on Gate E instead of re-running live RR
continuity experiments after the saved RR requirement is locally satisfied.

**Gate E checkpoint 2026-06-15 workout intensity proof detail:** physical
iPhone evidence in
`docs/evidence/gate-e/20260615T-workout-intensity-proof-detail-device-verify/`
adds explicit intensity proof to the confirmed-workout blocker. The app now
logs and displays `workout_intensity_proof` plus the P95/peak HR gaps. The
verified run showed
`workout_intensity_proof=received_hr_p95_90_below_threshold_121_by_31bpm`,
`workout_p95_hr=90`, `workout_p95_gap_bpm=31`, and
`workout_peak_gap_bpm=0`. That rules out "stream gaps only" as the current
workout failure: peak HR touched the 121 bpm threshold, but the received HR
distribution did not sustain workout-level intensity. Gate E remains
`user_confirmed`/auto-pending with `auto_gate_e_ready=0` and
`auto_detection_required=1`; no threshold was loosened and no metric was
promoted.

**Gate E checkpoint 2026-06-15 workout profile proof:** physical iPhone
evidence in
`docs/evidence/gate-e/20260615T-workout-profile-proof-device-verify/`
extends the confirmed-workout proof with the HRmax/profile sensitivity needed
to avoid bad fixes. The verified run logged
`workout_profile_proof=profile_fix_would_require_maxhr_128_current_189_lower_by_61bpm`,
`workout_p95_hr=90`, `workout_p99_hr=105`,
`workout_profile_max_hr=189`, and
`workout_required_profile_max_hr_for_p95_hrr50=128`. This rules out the
"lower the profile until the workout passes" path for the current gym evidence:
it would require an implausible 61 bpm max-HR reduction. Gate E remains
`user_confirmed`/auto-pending; no threshold or metric was promoted.

**Gate E checkpoint 2026-06-15 readiness UI user-confirmed state:** physical
iPhone evidence in
`docs/evidence/gate-e/20260615T-gate-e-user-confirmed-readiness-ui-device-verify-3/`
aligns the in-app Gate readiness row with Gate Status. The app now derives the
Gate E readiness row from `GateETrainingSummary`, so a confirmed sleep plus a
confirmed workout is shown as `user_confirmed` with an
`auto_detection_required` blocker instead of a generic `partial` state. The
verified run built green, installed and launched on the cabled iPhone, logged
real standard `2A37` RR, pulled `atria-gate-status.txt`, and left Atria running
in long-wear mode. Gate Status stayed honest:
`gate=E status=user_confirmed`, `confirmed_workouts=1`,
`confirmed_sleeps=1`, `auto_gate_e_ready=0`,
`auto_detection_required=1`, and
`workout_intensity_proof=received_hr_p95_90_below_threshold_121_by_31bpm`.
This makes the app clearer and more usable with one strap, but it is not a
Gate E pass.

**App usability checkpoint 2026-06-15 measured HRV reference warning:** physical
iPhone evidence in
`docs/evidence/app-usability/20260615T-measured-hrv-reference-pending-device-verify-unlocked/`
verified the user-facing HRV display policy after the phone was unlocked. Atria
now shows the clean local saved-RR RMSSD as a measured value (`main_rmssd=33`,
`rr_package_rmssd=32.7`) with `state=measured_reference_pending` and
`reason=external_rr_reference_required`, while logging
`metric_promotions=0`. Gate Status stayed honest with `gate=B
status=reference_pending`, `saved_rr_best_raw=368`,
`saved_rr_best_kept=361`, `saved_rr_best_conf=98`,
`saved_rr_best_gap_s=1.8`, `saved_rr_best_rmssd=32.7`,
`external_rr_reference_required=1`, and `reference_validated=0`. The same
device run proved the earlier "connecting/waiting" confusion was not strap
distance: iOS first denied launch because the phone was on the lock screen; once
opened, Atria scanned, matched `ADIDSHAFT'S WHO` at `rssi=-53`, connected, and
left the app running in standard-HR-only long-wear mode. This is a usability and
honesty fix only: Recovery, HRV baseline, HealthKit HRV, and Gate B remain
unpromoted until an independent RR/IBI reference passes the `+/-5 ms` RMSSD
contract.

Each phase: implement → `xcodebuild` clean → install+launch on device → confirm via os_log/diagnostics → update the relevant `docs/` page → focused commit.

---

## 5. Definition of done / "extreme accuracy" bar
- HR within ±2 bpm of a chest strap at rest; HRV (RMSSD) within ±5 ms of a reference 5-min recording.
- Recovery and Strain stable (no jitter) and explainable (tap → why).
- Every metric shows a confidence state; nothing fabricated when data is insufficient.
- Fully local, no subscription, survives reconnects, logs sessions unattended.
