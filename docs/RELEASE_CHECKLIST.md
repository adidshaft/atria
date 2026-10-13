# Release checklist

Every TestFlight / App Store build, in order.

1. **Build on a GA macOS machine** (Xcode Cloud). A beta-macOS archive is
   rejected as ITMS-90111.
2. **Gates green before upload**
   - `python3 test_handoff_static_checks.py`: no failure outside the recorded
     baseline (#44 tracks bringing it to zero).
   - Focused unit suites for everything the build touches.
3. **Archive the dSYM by UUID the day the build ships**
   - Xcode → Report navigator → Cloud → Build N → Archive - iOS → Artifacts →
     "Archive for Atria on iOS" → unzip → copy `dSYMs/` to
     `~/atria-validation/dsyms/<UUID>/`.
   - Check: `dwarfdump --uuid ~/atria-validation/dsyms/<UUID>/Atria.app.dSYM`
     prints the same UUID as `slice_uuid` in the build's reports.
4. **After every soak or field period, pull crash logs**
   ```bash
   bash pull_crashlogs.sh <label>
   ```
   Raw reports, symbolicated stacks and `SUMMARY.txt` land in
   `~/atria-validation/crashlogs/<date>-<label>/` (private — reports carry
   device identifiers; never commit them).
   Debug/TestFlight builds also write `Application Support/atria-diagnostics/`
   (`main-thread-stalls.log`, MetricKit `metrickit/*.json`, the reconnect-lease
   trail); a container pull picks those up.
5. **Append the summary** (counts by type for the new build, named top stacks)
   to the private crash folder and the dated memory note. A build with any
   `cpu_resource_fatal`, `0x8BADF00D`, SIGABRT or `diskwrites_resource` is not
   promoted.
