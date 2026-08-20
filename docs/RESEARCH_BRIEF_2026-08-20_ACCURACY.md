# Atria research brief — SpO2/skin-temp decode, HR-only sleep calibration, steps accuracy/freshness

Synthesized 2026-08-20 from three research passes (WHOOP 4.0 protocol RE, HR-only sleep-staging literature, wrist step-counting literature + vendor practice). Every claim carries its source URL.

---

## 1. SpO2 / skin-temp decoder — #31 can be unblocked

**Verdict: yes, for WHOOP 4.0.** The "SpO2 unrecoverable offline" claim is a WHOOP **5.0** limitation (26 time-multiplexed optical channels, red/IR never co-sample) per https://github.com/Sophonbot0/whoop-vault — it does not apply to 4.0, which has dedicated red + IR LEDs (MAX86171 AFE) and stores **both raw optical channels in the same historical record** (https://github.com/scandolo/openwhoop RESEARCH.md).

### What exactly to try

**Target the right records first.** SpO2/temp live only in the full-biometric `0x2F` HISTORICAL_DATA variants whose sub-stream-key byte is **0x0C (12) or 0x18 (24)** ("V12/V24" in openwhoop); other 0x2F keys are HR/RR-only. And WHOOP samples SpO2/temp **once daily during sleep**, so only sleep-window records are meaningfully populated (https://github.com/scandolo/openwhoop RESEARCH.md; https://github.com/bWanShiTong/reverse-engineering-whoop-post).

**Offsets, translated to Atria's frame** (openwhoop offsets are relative to the record body after the 3-byte type/streamkey/cmd header; Atria's payload byte 0 = 0x2F, so **Atria_payload_offset = openwhoop_offset + 3** — reconciled against the raw `aa5c00f02f 0c 07 8bb7 ... c8326966` capture in https://github.com/bWanShiTong/reverse-engineering-whoop-post):

| Field | openwhoop offset | Atria payload offset | Decode |
|---|---|---|---|
| spo2_red | [61:63] | [64:66] | u16 LE raw ADC |
| spo2_ir | [63:65] | [66:68] | u16 LE raw ADC |
| skin_temp_raw | [65:67] | [68:70] | u16 LE; °C = raw × 0.04 |
| skin_contact | [48] | [51] | u8, 0 = off-wrist |

Skin temp: valid raw ~582–1125 → 23–45 °C; raw < 100 = off-wrist; sensor is a Maxim MAX6631MTT per the openwhoop BOM. The ×0.04 scale is **explicitly flagged empirical and may vary per device** — ship skin temp as a **trend/relative signal, not a clinical absolute** (https://github.com/scandolo/openwhoop RESEARCH.md sections 4, 6.6, 9). That aligns with the relative-skin core already built (unwired) in the repo.

SpO2 value: ratio-of-ratios over a 30-sample window — R = (std(red)/mean(red)) / (std(ir)/mean(ir)); SpO2 = clamp(110 − 25R, 70, 100). The 110/25 constants are generic pulse-ox calibration → **trend-grade, not clinical**; consider fitting Atria's own constants against nights where the WHOOP app reported a value (https://github.com/scandolo/openwhoop RESEARCH.md 6.5).

### What to validate against before wiring

Dump one real 0x0C record from the strap and confirm the base offset in one shot: unix seconds at payload[7:11], HR at payload[17], first RR at payload[19:21] (≈ 60000/HR), and 3× f32 LE gravity at payload[36:48] with |g| ≈ 1.0. If those four line up, the SpO2/temp offsets above are correct; if not, adjust the single +3 base constant (validation recipe from https://github.com/scandolo/openwhoop RESEARCH.md; gravity/HR offsets independently corroborated by https://github.com/cs-balazs/gowhoop, which reads HR at data[14] and f32 gravity at data[33:45] and confirms Atria's 61080001–61080007 UUIDs).

Bonus fields already in the same record if useful later: resp_rate_raw at openwhoop [73:75], signal_quality [75:77], ambient_light [67:69], LED drive [69:73] (https://github.com/scandolo/openwhoop RESEARCH.md section 4).

---

## 2. HR-only sleep estimate calibration

### The published ceiling (what "good" looks like)

- Best-documented HR-only benchmark: Sridhar et al. 2020 — 4-class staging from instantaneous HR only, **77% accuracy / κ 0.66 in-domain, dropping to 72% / κ 0.55 out-of-domain** (https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/).
- PPG inter-beat intervals only: κ 0.65 with transfer learning; an ECG-trained model applied to PPG dropped to κ 0.57 — sensor-domain shift is real, relevant since WHOOP RR is PPG-derived (https://pmc.ncbi.nlm.nih.gov/articles/PMC8443610/).
- Motion is not the deciding factor: Fitbit's own PPG+accel paper got only κ 0.52 (https://iopscience.iop.org/article/10.1088/1361-6579/aa9047), and matched modern cardiac+motion pipelines sit only ~0.03–0.05 κ above HR-only (https://pmc.ncbi.nlm.nih.gov/articles/PMC10244431/).

### Is the ≥0.60 RR coverage gate right?

**Defensible but permissive, and unvalidated at that level.** The closest shipped HR-only analog (Neurobit-HRV) rejects epochs with ≥50% low-SNR samples AND whole nights with ≥10% rejected epochs — effectively a ~0.90 night-level bar (https://pmc.ncbi.nlm.nih.gov/articles/PMC9584568/). Sridhar applied no quality gate at all but ran on near-complete ECG-derived streams (https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/). **No published study validates staging accuracy as a function of RR coverage fraction, so the published κ figures cannot be assumed to hold at 60% coverage.** Suggested hardening:

1. Keep 0.60 as the floor for the labeled estimate, but add a **≥0.90 tier** with fuller confidence; treat 0.60–0.90 as the extra-hedged tier (Neurobit precedent, https://pmc.ncbi.nlm.nih.gov/articles/PMC9584568/).
2. Add a per-epoch validity rule; render unscorable epochs as gaps/"unscored," never interpolate.
3. Filter RR outliers (physiologic bounds + >5 SD removal, per Sridhar) before feature computation (https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/).
4. **Feature source: true RR intervals, not the 1 Hz HR samples** — every strong result runs on beat-to-beat tachograms; 1 Hz averaged HR destroys the 0.15–0.4 Hz respiratory-sinus-arrhythmia band that separates stages. 1 Hz HR is gap-filling context only (https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/, https://pmc.ncbi.nlm.nih.gov/articles/PMC8443610/).

### Stage-level honesty copy

- **Never split N1 vs N2** — N1 detection ~26.7% with 3.7% PPV; every credible cardiorespiratory paper ships 4-class max (https://pmc.ncbi.nlm.nih.gov/articles/PMC8443610/).
- **Deep (N3) is the systematically unreliable stage HR-only**: recall 0.49/0.48 (Sridhar, "underestimated in favor of light," https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/) and 0.38 (Neurobit, https://pmc.ncbi.nlm.nih.gov/articles/PMC9584568/). Hedge deep specifically in the estimate UI (e.g. "deep sleep is hardest to estimate without motion"), or fold deep+light into "non-REM" in the lowest-confidence tier. REM is the most trustworthy stage (F1 0.81, https://pmc.ncbi.nlm.nih.gov/articles/PMC8443610/; per-stage κ 0.751, https://pmc.ncbi.nlm.nih.gov/articles/PMC10244431/) — the hypnogram can present REM with more confidence than deep.
- **Keep the never-duration-credit rule**: quiet wake vs light sleep is the canonical HR-only confusion (wake sensitivity 0.67–0.80 without motion), so total-sleep-time is exactly the number most likely wrong (https://pmc.ncbi.nlm.nih.gov/articles/PMC7441407/, https://pmc.ncbi.nlm.nih.gov/articles/PMC9584568/).
- Market comparison: Fitbit degrades to a stage-free sleep log when its conditions aren't met (https://support.google.com/fitbit/answer/14236712); Oura degrades to totals plus an insight card explaining **why** (https://support.ouraring.com/hc/en-us/articles/39695406607507-Troubleshooting-Gaps-in-Sleep-Data). Atria's labeled upgrade-later estimate is already stronger than both — adopt the one pattern we lack: an explicit in-context "why tonight is an estimate" line ("strap was in HR-only mode; motion data pending") and a coarser sleep/wake-or-totals fallback below the 0.60 gate instead of nothing.
- If accuracy is ever quoted publicly: "roughly 70–77% epoch agreement with sleep-lab scoring, similar to published heart-rate-only research" — never parity with motion-validated nights.

### Algorithm upgrades worth it

- **Temporal context is the cheapest real win**: a 30-s epoch alone is insufficient; ~4.5-minute windows around each epoch (or whole-night sequence modeling) is the practice that produced the cited κ values (https://pubmed.ncbi.nlm.nih.gov/34322822/). If Atria's classifier is per-epoch, it is below best practice.
- Not worth chasing: raw-PPG models (SleepPPG-Net, κ 0.75) need the raw waveform, unavailable from a 1 Hz HR + RR stream (https://arxiv.org/abs/2202.05735).

---

## 3. Step accuracy + freshness

### Algorithm parameters worth auditing, in triage order

1. **Cadence-band lower edge.** Atria's 1.4–2.3 Hz band = 84–138 spm; free-living strolling commonly falls below 84 spm, and slow walking is the single biggest error source — MAPE ~40% at slow speeds, worst at the wrist (https://pmc.ncbi.nlm.nih.gov/articles/PMC9461139/); peak accelerations drop below thresholds under ~1.12 m/s and wrist accelerations are intrinsically smaller than hip (https://pmc.ncbi.nlm.nih.gov/articles/PMC5948774). Fix pattern: add a **slow-walk lane down to ~0.6–1.0 Hz gated by stricter periodicity/similarity checks**, rather than lowering the main band.
2. **Continuity / minimum-bout gates.** Verisense-style "sustain N regular windows before peaks count" (its five gates: magnitude, period min/max, similarity, variance SD < 0.025 g rejection, continuity — read from source at https://raw.githubusercontent.com/ShimmerEngineering/Verisense-Toolbox/master/Verisense_step_algorithm/verisense_count_steps.R) drop the 5–20 s bouts that dominate free-living totals; audit how many banked ticks Atria's run-length gates discard.
3. **Magnitude threshold vs low-arm-swing walking** (stroller, pockets, carrying) — structural to the wrist (https://pmc.ncbi.nlm.nih.gov/articles/PMC5948774); do not chase it with global threshold drops that buy false positives.

**Benchmark targets before tuning**: ≤10% MAPE on a scripted paced walk (CTA standard; best wrist devices ~4%, https://pmc.ncbi.nlm.nih.gov/articles/PMC9461139/); 12–20% free-living MAPE is the realistic band — best published wrist result is 12.5% (stepcount: 10-s walking classifier + find_peaks, prominence 0.1–1 g, min peak distance 0.2–2 s, ENMO lowpassed 5 Hz, https://pmc.ncbi.nlm.nih.gov/articles/PMC10187326/). Validate on a paced walk AND an ordinary errand day — treadmill-only overstates accuracy ~2×.

**Copy positioning**: WHOOP MG itself measured ~13% under on a 5,000-step hands-on test and showed no reading at the 1,000-step checkpoint — its steps "fill in… passively throughout the day" (https://www.androidpolice.com/5000-steps-with-fitbit-air-pixel-watch-whoop/); community deltas run 2k–5k/day vs Garmin/Samsung (https://www.community.whoop.com/t/significant-inaccuracy-in-step-count/13938). Do not claim parity with dedicated trackers; Atria's batch-offload lag matches the reference product's own display model — honesty is the differentiator.

### The "as of HH:MM" freshness pattern

Industry pattern (no vendor ships a verbatim "as of HH:MM" string, but all leaders ship sync-state honesty):
- WHOOP shows a **"Catching Up"** banner when strap data isn't current (support.whoop.com articles 360040194893 / 4414916912027, via search snippets — direct fetch 403).
- Garmin explicitly frames device-vs-app mismatch as sync lag: "The step count… updates when you sync your device," with a last-sync timestamp per device (https://www8.garmin.com/manuals/webhelp/vivofit4/EN-US/GUID-C54B136F-5E6D-450B-B9CC-E8A6619CAD49.html).

Recommended Atria pattern (extends the shipped "N% tracked" honesty to time):
- Persistent "Catching up"-style banner while motion backlog exists.
- Step tile stamped to the **newest settled motion tick, not wall clock**: "4,120 steps · tracked through 2:45 PM".
- In HR-only radio mode, say why and when: "Steps update after your strap syncs motion — motion is on the strap, syncing when connected."
- Never present a low/zero count as current — render "—" or "so far" phrasing below coverage threshold, back-fill silently when offload lands (WHOOP's own model, https://www.androidpolice.com/5000-steps-with-fitbit-air-pixel-watch-whoop/).

---

## 4. Do not bother

- **christianmeurer/whoop-reader's "SpO2 @ byte 5 / temp @ byte 6 of the realtime packet"** — contradicted by openwhoop's historical-record layout and by SpO2/temp being sleep-only daily samples (https://github.com/christianmeurer/whoop-reader vs https://github.com/scandolo/openwhoop).
- **The rusheelraj "/128 @ byte 73, AS6221" skin-temp scale** as a 4.0 fact — byte 73 is resp_rate_raw in the 4.0 layout; treat it as a 5.0/secondary hypothesis only (https://www.rusheelraj.com/blog/whoop/).
- **Cloning bWanShiTong/openwhoop directly** — the origin 404s; use a fork (scandolo/openwhoop preserves RESEARCH.md). Its promised "Part 2" (SpO2/temp) was never published.
- **Hunting for WHOOP's official SpO2/temp calibration coefficients or a fixed flash ring-buffer day-capacity constant** — neither exists anywhere; history is a trim-pointer/ACK log (drain cmd 22, trim u32 LE at HISTORY_END offset 10, ACK cmd 23; the frame sequence number is not even validated by the device) (https://github.com/scandolo/openwhoop).
- **A peer-reviewed WHOOP 4.0/MG step validation** — the feature shipped Oct 2024, still beta; only informal tests exist. Don't re-search.
- **A published study validating sleep staging vs RR-coverage fraction** — none exists; the 0.60 gate has no direct literature support either way (that's why the tiered hardening in §2 is judgment, not citation).
- **Paywalled/unfetchable sources already routed around**: Willemen 2014 (use Sridhar/Radha instead), Fonseca 2017 (PPG+accel anyway), medRxiv 2025 longitudinal paper (403), Wulterkens full text (403, headline κ 0.62 via summaries), nature.com direct pages (use PMC mirrors), docs.sleep.urbandroid.org (TLS error), support.whoop.com and web.archive.org (403/blocked — snippets only).
