# Fresh-machine setup

Getting Atria building, running on a real iPhone, and producing evidence you can
share safely. Everything here is verified against the current tree.

> **The Simulator cannot validate this project.** There is no CoreBluetooth
> hardware in it. The Simulator is useful for UI work and for the test suite;
> every claim about capture, drain, sleep, or steps needs a physical iPhone and a
> real strap.

---

## 1. What you need

| | |
|---|---|
| **Mac** | macOS with Xcode installed. For App Store uploads it must be a **released** macOS — see [Archiving](#6-archiving-and-the-itms-90111-trap). |
| **iPhone** | A physical device. Register it in your Apple Developer account. |
| **Strap** | A compatible WHOOP strap that is free to advertise over BLE — not actively bound to the official app. |
| **Signing** | An Apple Developer account. Free personal teams work for local development; the 7-day provisioning expiry becomes annoying during multi-day soaks. |

---

## 2. First build

```sh
open Atria/Atria.xcodeproj
```

Two shared schemes exist:

- **`Atria`** — the app, widget, and extensions.
- **`AtriaTests`** — the test suite. **Use this one for tests**, not the `Atria` scheme.

### Change the signing team

The project has a `DEVELOPMENT_TEAM` committed to it (`JP4HU7X6G7`). It is not
yours. In Xcode, select each target → **Signing & Capabilities** → set your own
team, and let Xcode regenerate the bundle identifiers if it offers.

Targets that need signing: the app, the widget extension, and the app group that
carries data between them. If the widget shows no data but the app works, the
**app group** is the first thing to check.

---

## 3. Running the tests

```sh
xcodebuild test -project Atria/Atria.xcodeproj -scheme AtriaTests \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

Two things will save you an afternoon:

- **Suites share a process and `UserDefaults`.** Tests that save through the real
  stores can clobber each other. Prefer pure-function fixtures over multi-save
  integration tests.
- **Fixture time bases matter.** Several sleep fixtures are anchored to specific
  dates. A fixture that reads the host's persisted state instead of its own
  anchor will produce suspiciously round numbers — an exact `10800.0` second
  duration means an onset clamp fired from real device state, not your fixture.

A fast, non-device sanity check:

```sh
./test_handoff_local.sh
```

---

## 4. Physical-device runs

The main harness builds, installs, launches, and captures logs in one command:

```sh
ATRIA_DEVICE_ID=<your-device-udid> ./live_device_debug.sh \
  --seconds 45 \
  --log logs/live-device/run.log \
  --log-gate-status \
  --standard-hr-only \
  --long-wear-mode \
  --leave-running
```

`ATRIA_DEVICE_ID` is **required** — the script does not guess. Find it with:

```sh
xcrun devicectl list devices
```

### Getting debug output at all

`AtriaDebugLog` is gated. It produces nothing unless the app is launched with a
diagnostic flag:

```
--atria-enable-debug-logs
```

…or any flag matching `--atria-log-*`, `--atria-export-*`, `--atria-validate-*`,
`--atria-confirm-*`, `--atria-schedule-*`, or one of the named diagnostic flags
in `AtriaDebugLogging.swift`.

It writes through `NSLogv`, which means it lands on **stdout**, not in the
unified log. `log stream` will not show it. Use `devicectl process launch
--console`, or read the file the harness writes.

### Read-only state dumps

These print computed values without mutating anything:

```
--atria-debug-dump-insights              # VO2max, fitness age
--atria-debug-dump-sleep                 # sleep candidates and gate decisions
--atria-debug-dump-pending-notifications # authorization, categories, pending IDs
```

### UI fixtures

For screens that need data you do not have yet:

```
--atria-ui-fixture history-sleep-review
--atria-ui-fixture history-activity-rhythm
```

### Pulling device state

```sh
./pull_atria_state.sh --device <udid> --evidence-dir evidence/<label>
```

Defaults to **runtime-only**, which is what you want. `--full-archive` copies the
whole historical archive and is only for an explicit archive-acceptance
checkpoint — it is how ~1.5 GB of duplicate identity indexes accumulated once.

---

## 5. Errors you will actually hit

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to install… error 10002` | The app is running and in use | Force-quit on device, or `./force_quit_ios_app.sh`, then reinstall |
| Install succeeds, but old behaviour persists | Stale incremental build — the binary did not actually rebuild | Clean build folder; verify the new symbol is present with `nm` before blaming the code |
| Device not found by `devicectl` | Not paired, locked, or "Trust This Computer" not accepted | Unlock the phone, re-accept trust, re-run `xcrun devicectl list devices` |
| Widget shows nothing, app is fine | App group misconfigured after re-signing | Re-check the app-group entitlement on both targets |
| Provisioning profile expired mid-soak | Free personal team, 7-day limit | Re-sign, or use a paid team for multi-day runs |
| Data "disappeared" after an install | On iOS 27 betas the data-container UUID **rotates** — but the data is migrated | Audit the new container before concluding data loss |
| Two `xcodebuild` runs at once wedge the Simulator | Concurrent builds against one simulator | Run them serially; reset the simulator if it wedges |
| Saved a file mid-build, binary is stale | The build captured the pre-save source | Rebuild; confirm with `nm` |

---

## 6. Archiving, and the ITMS-90111 trap

If App Store Connect rejects your upload as **"Invalid Binary" (ITMS-90111)**,
check the build machine's OS before touching anything else:

```sh
# in the built app's Info.plist
BuildMachineOSBuild=…
```

A **beta** macOS stamp there is the whole cause. Apple refuses binaries built on
a beta OS. Changing Xcode versions, SDKs, or deployment targets will not fix it —
build on a released macOS, or use Xcode Cloud.

Also note: Xcode Cloud stamps `CFBundleVersion` with the **run number** and
ignores `CURRENT_PROJECT_VERSION`. When ASC says the build number must be higher,
change it in **App Store Connect → Xcode Cloud → Settings → Build Number**, not
in the project.

---

## 7. Sharing logs safely

Device evidence is real health data about a real person. Before attaching
anything to an issue or PR:

**Safe to share as-is**

- Gate status lines (`logGateStatus` output) — counters, states, and blocker names
- Test output and `xcresult` summaries
- Protocol frame structure: byte offsets, field layouts, CRC behaviour
- Counts, coverage percentages, and durations

**Redact or do not share**

- **Raw HR/RR sample streams** — these are a biometric time series
- **Sleep and wake timestamps** — they reveal where someone lives and when they
  are home. This is the single most sensitive field in the project.
- **Workout GPS or location**, if any is ever added
- **Device names and BLE identifiers** — `WHOOP 4 ABC123` identifies a specific
  strap; peripheral UUIDs are stable per device
- **Full `sessions.json` / archive pulls** — assume these contain everything above
- Screenshots showing real values, unless you are the wearer and intend to

**Practical rule:** share the *shape* of the problem — counts, gates, reasons,
byte layouts — not the *values*. A gap is described by its start offset and
duration, not by the heart rates on either side of it.

`evidence/` and `logs/` are both gitignored. That is deliberate. If you need to
commit a fixture, stage it explicitly with `git add -f` and check it by eye first.

---

## 8. Where to start contributing

- **#8-adjacent docs work** — if something here was wrong or missing when you set
  up, that is the most valuable PR you can send.
- **Tests around RR parsing, correction, and confidence gates.**
- **Protocol decoding with evidence** — see
  [`WHOOP4_PROTOCOL_FINDINGS.md`](WHOOP4_PROTOCOL_FINDINGS.md).

Read [CONTRIBUTING.md](../CONTRIBUTING.md) first. The one rule that gets PRs
closed: **never ship a number the evidence does not support.** No estimating HRV
from HR-only data, no silently promoting low-confidence metrics, no filling an
empty card with a plausible value. A truthful blocker always beats a guess.
