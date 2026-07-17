# Paste-ready /goal prompt — written 2026-07-15 03:13 IST

Copy everything inside the fence into the next session (Codex or Claude).

```
/goal Complete the Atria step-reliability qualification in /Users/amanpandey/projects/atria without inventing evidence, then commit and push.

Work only on Atria — never Fizz or any other project.

Read these two files completely before doing anything, and follow them exactly:
1. docs/CLAUDE_HANDOFF_2026-07-15.md (original handoff + Addendum 1 & 2 with current-state corrections)
2. docs/GYM_CALIBRATION_RUNBOOK_2026-07-15.md (verified gym-day procedure, compile/invocation commands, fit-tool contract, honesty ledger)

Hard guardrails (unchanged):
- Use this Mac for builds; no CI/CD workflows. No Passwords app. No Brave/Safari (Chrome only if browser work is genuinely required).
- Preserve the dirty worktree; no destructive git operations.
- Do NOT install a build or stop/restart the running Atria app until the 11-sample overnight monitor process has exited on its own.
- Never invent strap-derived HR, strain, steps, SpO2, skin temperature, or historical metrics when evidence is insufficient. Keep validatedMetricLayoutVersions empty.
- Do not commit or push until physical verification passes end-to-end; commit author must be adidshaft <adidshaft@gmail.com>.

State at 2026-07-15 03:12 IST (verify from the filesystem, not this text):
- Branch codex/atria-reliability-widget-steps; dirty tree is the verified checkpoint (full simulator suite 1,318/1,318, 240 static checks, generic Release build all green; unsigned build at /tmp/atria-continuation-release, must not be installed yet).
- Overnight monitor PID 85262 alive, 5/11 hourly pulls, all ok; run dir logs/live-device/long-wear-monitor/overnight-45ddbc36-full-20260714; next pull ~03:48 IST, 11th ~08:47 IST, then the process exits.
- After it exits you MUST run the --recompute-existing-run command from the runbook §0 — the running process is old code that omits run_attributed_* fields; the recompute back-fills them.
- The acceptance gate will report FAIL no matter what: a real 360.4469 s union gap (first hour) and a serious thermal observation (sample 0) are permanent by construction, alongside whatever the remaining pulls determine. Report this honestly with the clean post-23:47 profile alongside; do not hide, relabel, or rerun to erase it. Whether the run is acceptable despite the gate is the user's call.
- On-device CSV capture window is armed until 2026-07-20 03:28:36 IST (re-verify on a fresh pull before the gym; re-arm procedure in runbook §0).

Remaining sequence (in order):
1. Let the monitor finish; recompute; write the honest pass/fail analysis.
2. Gym session with the user: the six-stage guided calibration (exact 0/100/100/100/200/0 counted steps, app exports the manifest via share sheet) plus the stress stages and live checklist in runbook §2.
3. Pull data ≥1 h after the last window (strap frames flush late); replay + fit with the verified commands in runbook §4; apply ONLY parameters the fit tool passes (rest false steps = 0, mean walk error ≤3 %, max ≤5 %); otherwise keep research labels.
4. Full simulator suite + 240 static checks + git diff --check + signed Release build; install on iPhone 3803F5B6-1666-56D3-A71A-62F131F6CE3B.
5. Physical verification via iPhone Mirroring: battery, reconnect, workout recovery, Activity save/edit/delete, Live Activity, route, share, journal deep link, sleep save, app-switch responsiveness.
6. Only when everything passes: commit all intended Atria changes and push to origin/codex/atria-reliability-widget-steps.

The goal is intentionally not complete until every step above passes with real evidence.
```
