# FABLE session loop prompt — Atria static-check + hygiene repair

Copy the block below into a new session running FABLE.

---

/loop 10min Repair the pre-existing static-check drift in the Atria repo and finish the test/repo hygiene work. Work on a NEW branch off `dev` named `fable/static-check-repair`.

CONTEXT — read these first, do not re-triage:
- `.claude/field-report-2026-08-19.md` — the 15-item field-report ledger from the Opus session. Sections near the end cover the repo cleanup and the test-script audit.
- A parallel Opus session is running RIGHT NOW on the same repo. Coordinate by staying off its files.

YOUR TASK, in priority order:

1. `test_handoff_static_checks.py` (15,525 lines) runs 189 tests with **54 failures + 2 errors**. This is PROVEN pre-existing: an identical run at `0c2602fb` (the commit before the Opus session started) gives exactly 54 failures + 2 errors. It is accumulated source-pin drift — the suite asserts on Swift source shapes that have since moved or been renamed.
   Run it with: `python3 -m unittest test_handoff_static_checks`
   For EACH failure, decide and record which of two things it is:
   - **stale pin** — the check is asserting on a symbol/file/string that legitimately moved or was renamed. Fix the CHECK.
   - **real defect** — the code genuinely no longer does what the check demands. Do NOT fix the Swift; write it up in the ledger with file:line and leave it for the Opus session.
   Never "fix" a failure by weakening an assertion into something that cannot fail. If a check is obsolete because the feature was deliberately removed, delete the check and say so in the commit.

2. Make the root `test_*.py` scripts runnable as one command. 23 of 26 pass under `unittest`, but `test_analyze_whoop4_gravity_walk.py` is pytest-style (4 bare `def test_*` functions) and pytest is not installed, and `test_decode_whoop_att_capture.py` is a `main()` script rather than a test. Add a single runner (a `scripts/run-tool-tests.sh`) that executes all three shapes and reports one pass/fail total. Do not rewrite the tests to fit the runner; make the runner handle what exists.

3. Triage the 4 git worktrees under `.claude/worktrees/` that still carry uncommitted edits: `agent-a3ac32b3300f4a61d` (5 modified files incl. `AtriaHealthScreen.swift`, `AtriaStressDetailView.swift`), `agent-a20fb84ef7bf7d604` (2), `agent-aaf58d1f2586859da` (3), `design-consent-fdd4ed` (4). For each: diff the working-tree changes, decide whether they are superseded by what is already on `main`/`dev`, and either (a) commit them to a clearly-named branch so nothing is lost, or (b) report that they are superseded and safe to discard. DO NOT delete a worktree with uncommitted changes without first preserving the diff somewhere.

4. `evidence/` still holds 649 MB across ~13,900 small files, all captured 2026-07-26…07-31. `.claude/evidence-pruned-2026-08-19.md` lists what was already removed. Propose (do not execute) a second-pass rule that would keep the analysis notes actually cited by `docs/WHOOP4_PROTOCOL_FINDINGS.md` and drop the rest, with a measured before/after estimate.

HARD CONSTRAINTS:
- **Do NOT touch the physical device.** No `xcrun devicectl`, no installs, no launches. The Opus session owns the phone and a second client will corrupt its measurements.
- **Do NOT edit these files** — the Opus session is actively changing them: `Atria/Atria/AtriaBLEManager.swift`, `Atria/Atria/AtriaHistoricalArchiveDurableStore.swift`, `Atria/Atria/AtriaManagedStorageInventory.swift`, `Atria/Atria/AtriaBLESchema.swift`, `.claude/field-report-2026-08-19.md`.
- Keep your own ledger at `.claude/fable-static-check-repair.md`. Update it before each turn ends.
- The Xcode test target uses a `PBXFileSystemSynchronizedRootGroup`: every `.swift` file under `AtriaTests/` is compiled by directory membership and is NOT listed in `project.pbxproj`. Comparing the two produces "307 orphaned tests" and is WRONG. All 307 are live.
- Before claiming a suite is green, print the actual counts. `tail -8` on xcodebuild output has already produced one false "8/8 green" claim in this project.
- Push commits as you go.

METHOD THAT WORKED IN THE OPUS SESSION AND IS WORTH COPYING:
- Establish the baseline before blaming your own change — run the suite at the pre-change commit in a detached worktree.
- When a heuristic hands you a deletion list, run the thing before you trust it. Name-shape inference produced two plausible-but-wrong deletion lists in one day (307 "orphaned" tests, 12 "missing subjects").
- Write the pass condition down BEFORE you look at the result.
