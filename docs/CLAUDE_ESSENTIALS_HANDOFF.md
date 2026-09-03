# Atria WHOOP essentials handoff for Claude

> **Superseded after implementation:** checkpoints in this document were implemented in `b5e0067f`. Use `docs/CLAUDE_FINAL_ACCEPTANCE_CHECKLIST.md` for the remaining work.

Date: 2026-08-10  
Repository: `/Users/amanpandey/projects/atria`  
Branch: `dev`  
Current pushed HEAD: `ad45af424dda852caa87b9b2da6d8ff0a3f34389` (`Advance retained step receipts`)  
Parent: `4149498318bd2eb2e1f3be262d84598e1948b280` (`Stabilize strap connectivity and continuous telemetry`)

## Mission

Do only the remaining release-critical work:

1. Remove the proven BLE callback/MainActor deadlock.
2. Make the CoreBluetooth A/B restoration-slot handoff crash-consistent.
3. Run focused tests.
4. Run one short, exact-build physical acceptance that proves HR ingress and the already-committed prior-cycle receipt fix.
5. If green, commit, push, and update GitHub issue #33.

Do **not** start another broad product audit, redesign UI, run a 40-minute soak, or upload TestFlight.

## What is already complete

- The large connectivity, motion-history, stress-v3, latest-night, CPU, and publication changes are already in pushed commit `41494983`.
- The retained prior-cycle step-receipt merge is already in pushed commit `ad45af42`.
- The receipt unit suite passed `45/45` after that commit.
- The earlier exact clean candidate suite passed `3996`, failed `0`, skipped `9` before the last two-file receipt commit.
- A signed device build of `ad45af42` passed codesign and source/install provenance checks.
- The device failure is now symbolicated and has a concrete root cause. Do not repeat broad diagnosis.

## Preserve the user's unrelated work

The main worktree contains unrelated chart edits. Do not stash, reset, rewrite, stage, or commit them:

```text
Atria/Atria/AtriaAboutMetricSheet.swift
Atria/Atria/AtriaActivityMonitor.swift
Atria/Atria/AtriaExpandedChart.swift
Atria/Atria/AtriaGraphInspector.swift
Atria/Atria/AtriaHealthspanDetailView.swift
Atria/Atria/AtriaOverviewSections.swift
Atria/Atria/AtriaSleepPlannerCharts.swift
Atria/Atria/AtriaStepsWeekChart.swift
Atria/Atria/AtriaStrainRecoveryComboChart.swift
Atria/Atria/AtriaTrendChart.swift
Atria/Atria/AtriaVitalsCollectionSections.swift
Atria/Atria/HRV.swift
Atria/Atria/HeartRate.swift
Atria/Atria/Insights.swift
```

This handoff file is coordination material. Do not include it in the app release commit unless the user explicitly asks.

## Proven failure 1: P0 deadlock and watchdog kill

This is not RF loss, a Bluetooth-off state, or CPU saturation.

Evidence:

- `/private/tmp/atria-watchdog-diagnosis/Atria-2026-08-10-140732.ips`
- `/private/tmp/atria-watchdog-diagnosis/Atria-2026-08-10-141718.ips`
- `/private/tmp/atria-receipt-smoke-ad45af42.y9i5dqk6/verdict.json`
- `/private/tmp/atria-receipt-smoke-ad45af42.y9i5dqk6/device-syslog.log`

The first and successor processes died with the same lock inversion.

### Main-thread side

```text
dispatch_sync
  -> AtriaBLECentralEventFence.retire(_:afterDraining:synchronizedTeardown:)
  -> AtriaBLEManager.rebuildCentralForWedgedSessionOnce(...)
  -> forceHardReconnectForPacketStall(...)
  -> performHRContinuityWatchdogAction(...)
```

Source anchors:

- `Atria/Atria/AtriaBLECentralEventFence.swift`, `retire`, currently around line 52; the blocking call is `delegateQueue.sync` around line 58.
- `Atria/Atria/AtriaBLEManager.swift`, `rebuildCentralForWedgedSessionOnce`, currently around line 22326; the fence drain is around line 22402.

### BLE-delegate side

The private `com.adidshaft.atria.ble-central` queue was in a direct `UserDefaults.set`, which synchronously posted `UserDefaults.didChangeNotification` and waited for its main-queue observer.

The two captured callback sites were:

- `didDiscoverCharacteristicsFor`, around `AtriaBLEManager.swift:43843`.
- Battery `didUpdateValueFor`, around `AtriaBLEManager.swift:44865`.

The synchronous observer is:

- `Atria/Atria/AtriaDefault.swift`, `AtriaDefaultChangeCenter.init`, around lines 119-126.
- It currently registers `UserDefaults.didChangeNotification` with `queue: .main`.

The cycle is exact:

```text
MainActor synchronously waits for ble-central to drain
ble-central writes UserDefaults
UserDefaults notification synchronously waits for MainActor
```

iOS killed PID `18499` after the 36-second scene-update allowance with `0x8BADF00D`. The app used only about 1% CPU during the watchdog interval, while bluetoothd continued delivering GATT traffic. This proves a wait/deadlock.

## Checkpoint 1: fix the defaults observer without weakening BLE fencing

### Required behavior

Change `AtriaDefaultChangeCenter` so an off-main `UserDefaults.didChangeNotification` never waits for MainActor:

1. Register the observer with `queue: nil`, not `.main`.
2. If the notification is delivered on the main thread, synchronously run the existing keyed-write suppression check. This preserves `isPerformingKeyedWrite` semantics.
3. If delivered off-main, enqueue the existing coalesced refresh onto `MainActor` and immediately return to the posting queue.
4. Preserve the equality gate and the five-second broad-refresh coalescer.
5. Do not read or mutate `boxesByKey`, `refreshTask`, counters, or `isPerformingKeyedWrite` off MainActor.

A suitable shape is:

```swift
observer = NotificationCenter.default.addObserver(
    forName: UserDefaults.didChangeNotification,
    object: store,
    queue: nil
) { [weak self] _ in
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            guard self?.isPerformingKeyedWrite == false else { return }
            self?.scheduleExternalRefresh()
        }
    } else {
        Task { @MainActor [weak self] in
            self?.scheduleExternalRefresh()
        }
    }
}
```

Adapt this as needed for strict-concurrency compilation. The invariants matter more than the exact syntax.

### Do not use these shortcuts

- Do not fix only the two observed `UserDefaults.set` calls. Other BLE callbacks write defaults and can reproduce the same cycle.
- Do not delete the delegate-lane drain.
- Do not replace the drain with an unordered fire-and-forget teardown.
- Do not remove keyed-write suppression, the equality guard, or refresh coalescing.

The current synchronous drain protects an admitted callback from crossing the central/peripheral epoch replacement boundary. Keep it for this minimal pass once the broad observer no longer blocks callback writers. If you choose an async barrier redesign instead, it must preserve exactly the same ordering and needs substantially more tests; that is not the essentials-first recommendation.

### Required tests

Edit `Atria/AtriaTests/AtriaDefaultCoalescingTests.swift`.

Add a deterministic regression that:

1. Creates a dedicated suite `UserDefaults` and at least one `AtriaDefaultBox`.
2. Posts/writes the defaults change from a BLE-like serial background queue.
3. Deliberately blocks the main test thread with a **bounded** semaphore wait of roughly 250 ms.
4. Asserts the background writer returns before the wait expires. The old `queue: .main` implementation times out here.
5. Then yields MainActor, flushes the pending refresh, and verifies the box receives the new value.

Also retain or strengthen these existing guarantees:

- A wrapped/keyed write refreshes only its own key and produces no broad pass, including after `Task.yield()`/flush.
- Twenty rapid external writes still coalesce into exactly one broad refresh pass.
- `externalRefreshInterval` remains at least 2.5 seconds.

Checkpoint 1 is green only when `AtriaDefaultCoalescingTests` passes and the app target type-checks with no new concurrency error.

## Proven failure 2: crash-inconsistent A/B restoration-slot switch

The watchdog repair was running on a live `...recovery-b-v1` CoreBluetooth session. `rebuildCentralForWedgedSessionOnce` computed the alternate base slot and persisted it **before** the old central finished draining. The deadlock then prevented the swap, and iOS killed the process.

Result on restoration:

- The surviving CoreBluetooth session still belonged to `recovery-b-v1`.
- The relaunched app read the prematurely persisted base slot and constructed the unsuffixed base central.
- bluetoothd temporarily had two sessions for one physical strap.
- It later reaped the old session and disabled its CCCDs, including HR handle `0x002b`.
- The successor received 379 bluetoothd GATT indications, but app raw and accepted counters remained unchanged after its callback lane wedged.

This is a write-ahead crash-consistency bug in addition to the defaults deadlock.

Relevant source:

- `AtriaBLEManager.centralRestoreIdentifier`, around lines 4218-4234.
- `persistCentralRecoveryRestoreIdentifier`, around lines 4241-4250.
- `rebuildCentralForWedgedSessionOnce`, around lines 22326-22447.
- The current call to `persistCentralRecoveryRestoreIdentifier` occurs before `centralEventFence.retire`.

## Checkpoint 2: make the restore-slot handoff crash-consistent

Inside `rebuildCentralForWedgedSessionOnce`:

1. Continue computing `replacementRestoreIdentifier` before teardown.
2. Do **not** publish that replacement identifier to `restoreSlotsByBase` while the old central still owns callback authority.
3. First complete the old central's drain, exact central retirement, and peripheral epoch invalidation.
4. Then persist `replacementRestoreIdentifier`.
5. Then construct the replacement `CBCentralManager` with that exact identifier, install it in `centralEventFence`, mark its power-on ownership, and resume the delegate queue.
6. Move the related `centralUnavailableRecoveryAttempt` pending-bit mutation to the same post-drain/pre-construction commit point. A process death before the drain must relaunch into the old slot; a death after the drain but before/during construction must relaunch into the new slot.

Required ordering:

```text
compute replacement ID
  -> drain old delegate lane
  -> retire old central + invalidate peripheral epoch
  -> persist replacement ID/pending state
  -> construct replacement central with that ID
  -> install exact central fence token
  -> mark replacement power-on ownership
  -> resume delegate lane
```

Do not create both base and recovery managers. There must be one production central owner.

### Required tests

Use `Atria/AtriaTests/AtriaBLECentralEventFenceTests.swift` and, only where existing assertions belong, `AtriaBLERecoveryCadenceTests.swift`.

Keep all existing semantic tests green:

- An admitted callback finishes before replacement.
- Peripheral epoch invalidation occurs inside the drain boundary.
- Behind-barrier callbacks cannot capture old authority.
- A retired token cannot inspect/consume replacement power-on markers.
- Base/recovery slot resolution remains scoped to the matching protected-owner base.

Add/strengthen a crash-order regression that proves:

```text
centralEventFence.retire(...) < persistCentralRecoveryRestoreIdentifier(...) < CBCentralManager(...replacementRestoreIdentifier...)
```

Also prove the pending-bit write, when applicable, is after retirement and before replacement construction.

Checkpoint 2 is green only when the focused fence/recovery tests pass without weakening any exact-object or epoch assertion.

## Checkpoint 3: focused validation only

Run these test classes serially, one simulator worker:

```text
AtriaDefaultCoalescingTests
AtriaBLECentralEventFenceTests
AtriaBLERecoveryCadenceTests
AtriaBLELiveContinuityPolicyTests
AtriaBLEBackgroundFastLaneTests
```

Then run:

```text
xcrun swiftc -frontend -parse Atria/Atria/AtriaDefault.swift
xcrun swiftc -frontend -parse Atria/Atria/AtriaBLECentralEventFence.swift
xcrun swiftc -frontend -parse Atria/Atria/AtriaBLEManager.swift
xcrun swiftc -frontend -parse Atria/AtriaTests/AtriaDefaultCoalescingTests.swift
xcrun swiftc -frontend -parse Atria/AtriaTests/AtriaBLECentralEventFenceTests.swift
git diff --check
```

Use the `AtriaTests` scheme. Do not run the entire 4,000-test suite unless a focused failure points outside these files.

Expected edit scope:

```text
Atria/Atria/AtriaDefault.swift
Atria/Atria/AtriaBLEManager.swift
Atria/AtriaTests/AtriaDefaultCoalescingTests.swift
Atria/AtriaTests/AtriaBLECentralEventFenceTests.swift
```

`AtriaBLERecoveryCadenceTests.swift` may change only if its existing structural assertion must be made semantic. `AtriaBLECentralEventFence.swift` should not need production changes for the recommended minimal fix.

Do not edit the receipt store again unless its focused test fails:

```text
Atria/Atria/AtriaWhoop4MotionTickDailyStore.swift
Atria/AtriaTests/AtriaWhoop4MotionTickDailyStoreTests.swift
```

## Checkpoint 4: create an exact clean candidate

Because the main worktree has unrelated user edits, provenance validation must use a clean exact commit.

1. Stage only the files listed in the expected scope.
2. Do not stage this handoff document or any of the 14 chart files.
3. Commit with:

```text
adidshaft <adidshaft@gmail.com>
```

4. Create a clean detached worktree at the new commit under `/private/tmp`.
5. Build and install from that detached tree, not the dirty shared worktree.
6. Use `tools/app_build_provenance.py` / the existing device harness to bind and verify the installed binary to the exact clean commit.

Do not push until the short physical gate is green; if it fails, make a new focused fix commit and retest.

## Checkpoint 5: short physical acceptance, 5-10 minutes

Install in place so retained device data remains available. No TestFlight.

### Process/watchdog

- One exact Atria PID and exact bundle path for the whole window.
- No new `0x8BADF00D`, watchdog, jetsam, or CPU-limit report.
- No automatic successor PID.

### BLE ingress

- `rawDelta > 0`.
- `acceptedDelta > 0`.
- `rawDelta == acceptedDelta` over the bounded window.
- bluetoothd 2A37 indications and Atria raw/accepted persistence both advance at approximately live cadence.
- Zero/held/dropped and raw/accepted gap counters do not grow.
- Link attempt/success/disconnect/failure, app-cancel, and false-Bluetooth-off counters do not churn.
- Status remains truthfully connected/live/notifying when GATT is arriving.

### Restoration namespace

- Exactly one production CoreBluetooth session owns the strap.
- The app checks into the persisted active base/recovery restore identifier; it must not start a competing alternate merely because a swap was interrupted.
- No `Reaping Disconnected Session` for a competing Atria owner.
- No old-owner reap disables HR CCCD/handle `0x002b` underneath the canonical owner.

### Prior-cycle receipt

The code fix is already committed; this run only proves it can execute once BLE/MainActor is no longer deadlocked.

Starting physical state in the failed run:

```text
receipt sha256: 9067b63a3af0db280782b88eca2ab668ccede8a9bbe7e07f1185d55d32651e1c
capturedThrough: 808009231.7216797
knownCoverageSeconds: 44058
```

Available compact evidence extended roughly 9,554 seconds later. Acceptance requires the immediately-prior receipt to durably advance `capturedThrough` (and change content/hash) without reducing the strongest published motion ticks, steps, or known coverage.

If HR ingress is green but the receipt still does not advance, capture the candidate receipt and `AtriaWhoop4MotionTickDailyStore.saveValidated` decision before changing code. Do not blindly rewrite the already-tested merge.

## Optional restoration smoke after the first green window

Only if the user permits one additional device action:

1. Capture the exact active restore identifier while connected.
2. Terminate the process once, without toggling Bluetooth or forgetting the device.
3. Allow normal CoreBluetooth restoration/system relaunch.
4. Verify the successor constructs the same persisted active restore slot, has one production central session, accepts the first and subsequent 2A37 callbacks, and advances raw/accepted counters for 2-5 minutes.

This is the most direct saved-device restoration proof, but it is secondary to the no-watchdog + live-ingress smoke above.

## Checkpoint 6: finish Git and issue #33

When all required checkpoints are green:

1. Push `dev` to `origin`.
2. Verify `git rev-list --left-right --count @{upstream}...HEAD` is `0 0`.
3. Comment on GitHub issue #33 with:
   - exact commit SHA;
   - focused test totals/result bundles;
   - signed-build/provenance result;
   - PID/watchdog result;
   - raw/accepted deltas;
   - restoration-namespace result;
   - receipt before/after values;
   - explicit statement that no TestFlight upload occurred.
4. Keep issue #33 open if its acceptance text still requires TestFlight. The current instruction forbids TestFlight, so do not falsely close it as fully redistributed.

## Failure routing

- Background defaults writer still blocks: the observer is still synchronously targeting main, or another main-queue observer was introduced.
- Keyed writes trigger a broad pass: the main-thread suppression was deferred and observed after `isPerformingKeyedWrite` reset.
- Fence tests fail: callback-drain/epoch ordering was weakened; restore the ordering instead of changing the test to accept a race.
- Relaunch selects the opposite slot after a pre-drain kill: replacement persistence still occurs too early.
- bluetoothd GATT advances but raw/accepted remain zero: immediately pull the current crash/sample and inspect the BLE delegate queue; do not blame RF.
- Raw/accepted are green but receipt is static: collect the candidate `knownCoverageSeconds`, `capturedThrough`, and save decision; only then revisit the daily store.
- A new PID appears: stop the acceptance window and pull the `.ips`; do not average across processes.

## Definition of done

- [ ] `UserDefaults.didChangeNotification` cannot synchronously block a BLE callback on MainActor.
- [ ] Keyed-write suppression and five-second broad coalescing still work.
- [ ] Replacement restore-slot persistence occurs after old-owner retirement and before replacement construction.
- [ ] Focused test classes pass with zero failures.
- [ ] Parse and `git diff --check` pass.
- [ ] Exact clean signed build/provenance pass.
- [ ] One PID survives 5-10 minutes with no watchdog.
- [ ] Raw and accepted HR both advance, remain equal, and show no new gaps/churn/false-off.
- [ ] Exactly one restoration namespace owns the strap.
- [ ] Immediately-prior receipt advances from the retained evidence.
- [ ] Focused commit is pushed and issue #33 is updated.
- [ ] No TestFlight upload is performed.

## Compact prompt to give Claude

> Read `docs/CLAUDE_ESSENTIALS_HANDOFF.md` completely. Implement only Checkpoints 1 and 2, preserving the unrelated dirty chart files and the existing BLE fence semantics. Run only the focused Checkpoint 3 tests. Create an exact clean candidate and perform the short Checkpoint 5 device smoke. If green, push and update issue #33; do not upload TestFlight. Stop on any PID turnover or new crash and report the exact evidence instead of broadening scope.
