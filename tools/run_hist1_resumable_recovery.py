#!/usr/bin/env python3
"""Phased, dry-run-first orchestration for a 2-10 minute HIST-1 trial.

The tool never installs, launches, terminates, signals, pairs, or changes radio
state. It takes read-only state pulls and watches an already-running console
log. The user's only physical operations are taking the strap out of range (or
turning Bluetooth off) and bringing it back when a phase says to do so.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PULL = ROOT / "pull_atria_state.sh"
VERIFY = ROOT / "tools" / "verify_hist1_resumable_recovery.py"
PHASES = ("prepare", "post-reconnect-drain", "interrupt", "resume-final")


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    data = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def load(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise SystemExit(f"Invalid state object: {path}")
    return value


def blocking_preexisting_window_ids(ledger: dict[str, Any]) -> list[str]:
    """Return every window that can absorb or precede the controlled gap.

    Production reuses an existing open window when the next disconnect begins,
    then closes that older window on reconnect.  Such a window is therefore as
    unsafe as an already-closed recovery candidate: either one would prevent
    the marker-bounded trial from owning the transaction.  The sole exception
    is a legacy coalesced closed envelope without an exact expected-second mask;
    Swift deliberately refuses to select that ambiguous record.
    """
    return [
        str(window.get("id", "missing"))
        for window in ledger.get("windows", [])
        if isinstance(window, dict)
        and not (
            window.get("end") is not None
            and
            window.get("reason") == "coalesced_unresolved_history"
            and window.get("expectedSecondBitsBase64") is None
        )
    ]


def phase_record(directory: Path, phase: str, complete: bool = True) -> None:
    atomic_json(directory / "hist1-phase.json", {
        "phase": phase, "complete": complete, "recordedAtUnix": time.time(),
    })


def pull(device: str, bundle: str, destination: Path, runtime_only: bool) -> None:
    command = [str(PULL), "--device", device, "--bundle-id", bundle,
               "--installed-provenance-only", "--evidence-dir", str(destination)]
    if runtime_only:
        command.insert(-2, "--runtime-only")
    subprocess.run(command, cwd=ROOT, check=True)
    summary = destination / "pull-summary.txt"
    text = summary.read_text(encoding="utf-8", errors="replace")
    required = ["app_provenance_status=pass", "active_journal_final_status=ok"]
    if runtime_only:
        required.append("process_status=running")
    missing = [item for item in required if item not in text]
    if missing:
        raise SystemExit(f"Fail-closed pull {destination}: missing {', '.join(missing)}")


def marker_path(run: Path) -> Path:
    return run / "controlled-gap-marker.json"


def state_path(run: Path) -> Path:
    return run / "orchestrator-state.json"


def log_bytes(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError:
        return b""


def wait_for(path: Path, start_offset: int, predicates: list[bytes], timeout: int) -> bytes:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = log_bytes(path)[start_offset:]
        if all(token in data for token in predicates):
            return data
        time.sleep(0.25)
    raise SystemExit("Timed out waiting for required recovery markers; evidence retained.")


def dry_run(args: argparse.Namespace) -> int:
    run = args.run.resolve()
    print("hist1_orchestrator_mode=dry_run")
    print(f"phase={args.phase}")
    print(f"run={run}")
    print("device_mutation=none")
    print("app_lifecycle_mutation=none")
    if args.phase == "prepare":
        print(f"controlled_gap_seconds={args.gap_seconds}")
        print("will_preserve=pre-gap-runtime,pre-gap-full,marker")
        print("next_manual_action=after_execute_move_strap_out_of_range_or_turn_bluetooth_off")
    elif args.phase == "post-reconnect-drain":
        print("will_preserve=mid-drain-runtime,mid-drain-full,interrupted-log-prefix")
        print("waits_for=gap-bound-authority,durable-batch,accepted-ack")
        print("next_manual_action=when_prompted_move_out_of_range_or_turn_bluetooth_off")
    elif args.phase == "interrupt":
        print("will_require=disconnect_after_first_accepted_batch,no_terminal")
        print("will_preserve=interrupt-runtime,interrupt-full,complete-interrupted-log")
        print("next_manual_action=after_execute_return_in_range_or_turn_bluetooth_on")
    else:
        print("will_require=new_generation,terminal,live_restore,CAS,coverage,receipts")
        print("will_preserve=post-resume-runtime,post-resume-full,resumed-log,verifier")
    print("execute_flag_required=1")
    return 0


def prepare(args: argparse.Namespace) -> None:
    if not 120 <= args.gap_seconds <= 600:
        raise SystemExit("--gap-seconds must be between 120 and 600")
    run = args.run.resolve()
    if run.exists():
        raise SystemExit(f"Run path already exists: {run}")
    if args.live_log is None or not args.live_log.is_file():
        raise SystemExit(
            "prepare --execute requires --live-log for the already-running console; "
            "reconnect evidence cannot be captured safely from a later offset."
        )
    run.mkdir(parents=True)
    runtime = run / "pre-gap-runtime"
    full = run / "pre-gap-full"
    pull(args.device, args.bundle_id, runtime, True)
    phase_record(runtime, "prepare")
    pull(args.device, args.bundle_id, full, False)
    phase_record(full, "prepare")
    ledger_files = list((full / "historical-gap-ledger-v2").rglob(
        "historical-gap-ledger-v2.json"
    )) if (full / "historical-gap-ledger-v2").is_dir() else []
    if len(ledger_files) != 1:
        raise SystemExit(
            "Pre-gap canonical ledger is missing or ambiguous; no user action is safe."
        )
    ledger = load(ledger_files[0])
    if ledger.get("version") != 2 or ledger.get("state") != "valid":
        raise SystemExit(
            "Pre-gap canonical ledger is not valid v2 state; no user action is safe."
        )
    candidates = blocking_preexisting_window_ids(ledger)
    if candidates:
        identifiers = ",".join(candidates)
        raise SystemExit(
            "A pre-existing open or selectable recovery window would absorb or "
            f"precede the controlled gap ({identifiers}). Evidence is preserved; do not "
            "move away or toggle Bluetooth. Resolve the older candidate first."
        )
    now = time.time()
    live_log = args.live_log.resolve()
    marker = {
        "version": 1, "gapStartUnix": now, "reconnectUnix": None,
        "plannedGapSeconds": args.gap_seconds, "device": args.device,
        "bundleIdentifier": args.bundle_id,
    }
    state = {
        "version": 1, "phase": "prepared",
        "consoleOffset": len(log_bytes(live_log)),
        "liveLog": str(live_log), "interruptGeneration": None,
        "createdAtUnix": now,
    }
    atomic_json(marker_path(run), marker)
    atomic_json(state_path(run), state)
    print("hist1_prepare_status=ready")
    print(f"gap_start_unix={now:.6f}")
    print(f"planned_gap_seconds={args.gap_seconds}")
    print("manual_action=move_strap_out_of_range_or_turn_bluetooth_off_now")
    print("then=return_after_planned_gap_and_run_post-reconnect-drain")


def post_reconnect(args: argparse.Namespace) -> None:
    run = args.run.resolve()
    state = load(state_path(run))
    marker = load(marker_path(run))
    if state.get("phase") != "prepared":
        raise SystemExit("Run is not in prepared phase")
    reconnect = time.time()
    duration = reconnect - float(marker["gapStartUnix"])
    if not 120 <= duration <= 600:
        raise SystemExit(f"Observed gap is {duration:.1f}s; required 120-600s")
    if args.live_log is None or not args.live_log.is_file():
        raise SystemExit("--live-log must name the already-running console log")
    if str(args.live_log.resolve()) != state.get("liveLog"):
        raise SystemExit("--live-log must be the same console captured during prepare")
    offset = int(state["consoleOffset"])
    marker["reconnectUnix"] = reconnect
    atomic_json(marker_path(run), marker)
    runtime = run / "mid-drain-runtime"
    full = run / "mid-drain-full"
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), runtime, True)
    phase_record(runtime, "post-reconnect-drain")
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), full, False)
    phase_record(full, "post-reconnect-drain")
    evidence = wait_for(args.live_log, offset, [
        b"historical_full_drain_authority status=armed",
        b"historyDrain status=durable",
        b"historyAck status=accepted",
    ], args.timeout)
    interrupted_log = run / "interrupted-recovery.log"
    interrupted_log.write_bytes(evidence)
    with interrupted_log.open("rb") as handle:
        os.fsync(handle.fileno())
    state.update({
        "phase": "interrupt_prompted", "consoleOffset": offset,
        "interruptPromptLogBytes": len(evidence), "interruptPromptAtUnix": time.time(),
    })
    atomic_json(state_path(run), state)
    print("hist1_post_reconnect_status=first_batch_durable_and_acknowledged")
    print("manual_action=move_strap_out_of_range_or_turn_bluetooth_off_NOW")
    print("then=run_interrupt_phase_after_the_app_reports_disconnected")


def interrupt(args: argparse.Namespace) -> None:
    run = args.run.resolve()
    state = load(state_path(run))
    marker = load(marker_path(run))
    if state.get("phase") != "interrupt_prompted":
        raise SystemExit("Run is not waiting for interruption evidence")
    if args.live_log is None or not args.live_log.is_file():
        raise SystemExit("--live-log must name the same running console log")
    if str(args.live_log.resolve()) != state.get("liveLog"):
        raise SystemExit("--live-log must be the same console captured during prepare")
    offset = int(state["consoleOffset"])
    data = wait_for(args.live_log, offset, [b"historyAck status=accepted"], args.timeout)
    disconnect_tokens = (b"didDisconnect", b"status=disconnected", b"link_lost")
    if not any(token in data for token in disconnect_tokens):
        raise SystemExit("No post-batch disconnect marker yet; keep the strap away and retry.")
    # A terminal from the interrupted generation is an invalid trial. Preserve
    # it, fail, and start a new run rather than pretending the later disconnect
    # interrupted the drain.
    if b"historyTerminal status=received" in data:
        (run / "interrupted-recovery.log").write_bytes(data)
        raise SystemExit("Drain became terminal before interruption; start a new trial.")
    (run / "interrupted-recovery.log").write_bytes(data)
    runtime = run / "interrupt-runtime"
    full = run / "interrupt-full"
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), runtime, True)
    phase_record(runtime, "interrupt")
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), full, False)
    phase_record(full, "interrupt")
    state.update({"phase": "interrupted", "interruptedLogBytes": len(data),
                  "interruptedAtUnix": time.time()})
    atomic_json(state_path(run), state)
    print("hist1_interrupt_status=proven_nonterminal_gap_retained")
    print("manual_action=return_in_range_or_turn_bluetooth_on_now")
    print("then=run_resume-final")


def resume(args: argparse.Namespace) -> None:
    run = args.run.resolve()
    state = load(state_path(run))
    marker = load(marker_path(run))
    if state.get("phase") != "interrupted":
        raise SystemExit("Run is not in interrupted phase")
    if args.live_log is None or not args.live_log.is_file():
        raise SystemExit("--live-log must name the same running console log")
    if str(args.live_log.resolve()) != state.get("liveLog"):
        raise SystemExit("--live-log must be the same console captured during prepare")
    start = int(state["consoleOffset"]) + int(state["interruptedLogBytes"])
    data = wait_for(args.live_log, start, [
        b"historical_full_drain_authority status=armed",
        b"historyTerminal status=received",
        b"historical_full_drain_publish status=resolved",
        b"offline_sync status=complete",
    ], args.timeout)
    resumed_log = run / "resumed-recovery.log"
    resumed_log.write_bytes(data)
    runtime = run / "post-resume-runtime"
    full = run / "post-resume-full"
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), runtime, True)
    phase_record(runtime, "resume-final")
    pull(str(marker["device"]), str(marker["bundleIdentifier"]), full, False)
    phase_record(full, "resume-final")
    verifier = run / "resumable-recovery-verifier.txt"
    command = [
        sys.executable, str(VERIFY), "--marker", str(marker_path(run)),
        "--pre-gap-full", str(run / "pre-gap-full"),
        "--mid-drain-full", str(run / "mid-drain-full"),
        "--interrupt-full", str(run / "interrupt-full"),
        "--post-resume-full", str(full),
        "--interrupted-log", str(run / "interrupted-recovery.log"),
        "--resumed-log", str(resumed_log),
    ]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    verifier.write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode != 0:
        raise SystemExit(f"Final verification failed; inspect {verifier}")
    state.update({"phase": "verified", "verifiedAtUnix": time.time(),
                  "verifierSHA256": hashlib.sha256(verifier.read_bytes()).hexdigest()})
    atomic_json(state_path(run), state)
    print(result.stdout, end="")
    print(f"hist1_resumable_evidence={run}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=PHASES)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--device", default=os.environ.get("ATRIA_DEVICE_ID", ""))
    parser.add_argument("--bundle-id", default="com.adidshaft.atria")
    parser.add_argument("--gap-seconds", type=int, default=180)
    parser.add_argument("--live-log", type=Path)
    parser.add_argument("--timeout", type=int, default=240)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not args.execute:
        return dry_run(args)
    if args.phase == "prepare" and not args.device:
        parser.error("prepare --execute requires --device or ATRIA_DEVICE_ID")
    {"prepare": prepare, "post-reconnect-drain": post_reconnect,
     "interrupt": interrupt, "resume-final": resume}[args.phase](args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
