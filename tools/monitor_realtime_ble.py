#!/usr/bin/env python3
"""Non-invasive realtime BLE validation monitor for Atria physical-device runs."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_DEVICE = "3803F5B6-1666-56D3-A71A-62F131F6CE3B"
DEFAULT_BUNDLE = "com.adidshaft.atria"
PREFS_SOURCE = "Library/Preferences/com.adidshaft.atria.plist"

COUNTER_KEYS = [
    "whoop.link.attempts",
    "whoop.link.disconnects",
    "whoop.link.successes",
    "whoop.watchdog.hrContinuityCount",
    "whoop.watchdog.acceptedHRCount",
    "whoop.sample.rawNotifications",
    "whoop.sample.acceptedSamples",
    "whoop.keepalive.ticks",
]

STATUS_KEYS = [
    "whoop.sample.lastStatus",
    "whoop.link.lastStatus",
    "whoop.link.lastReason",
    "whoop.watchdog.lastAction",
    "whoop.keepalive.armed",
    "whoop.keepalive.lastStatus",
    "whoop.keepalive.lastAction",
    "whoop.keepalive.lastSilence",
    "whoop.keepalive.ticks",
    "whoop.radio.standardHROnly",
    "whoop.longWear.enabled",
]

PULL_STATE_SUMMARY_KEYS = [
    "process_status",
    "sessions_status",
    "sessions_count",
    "file_durability_status",
    "latest_session_label",
    "latest_session_points",
    "latest_session_rr_points",
    "latest_session_duration_s",
    "active_journal_final_status",
    "active_journal_reconstructed_from_segments",
    "active_journal_samples",
    "active_journal_rr_values",
    "active_journal_freshness",
    "active_journal_continuity_status",
    "active_journal_continuity_reason",
    "active_journal_duration_s",
    "active_journal_interruption_class",
    "live_stream_consistency_status",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def copy_preferences(device: str, bundle: str, destination: Path) -> tuple[int, str]:
    result = subprocess.run(
        [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "from",
            "--device",
            device,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            bundle,
            "--source",
            PREFS_SOURCE,
            "--destination",
            str(destination),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return result.returncode, result.stdout


def read_preferences(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    return {key: data.get(key, 0) for key in COUNTER_KEYS + STATUS_KEYS}


def numeric(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    return 0


def compute_delta(previous: dict[str, Any] | None, current: dict[str, Any]) -> dict[str, int]:
    if previous is None:
        return {key: 0 for key in COUNTER_KEYS}
    return {key: numeric(current.get(key)) - numeric(previous.get(key)) for key in COUNTER_KEYS}


def evaluate_sample(delta: dict[str, int], current: dict[str, Any], worn: bool) -> list[str]:
    flags: list[str] = []
    if worn and delta["whoop.sample.rawNotifications"] <= 0:
        flags.append("NO_NEW_DATA")
    if delta["whoop.link.disconnects"] >= 3:
        flags.append("DISCONNECT_CHURN")
    if delta["whoop.watchdog.hrContinuityCount"] >= 3:
        flags.append("TEARDOWN_CHURN")
    if worn and current.get("whoop.sample.lastStatus") == "zero_contact":
        flags.append("ZERO_CONTACT")
    if current.get("whoop.link.lastStatus") not in {None, "connected"}:
        flags.append("NOT_CONNECTED")
    if current.get("whoop.longWear.enabled") and current.get("whoop.keepalive.armed"):
        if delta["whoop.keepalive.ticks"] <= 0:
            flags.append("KEEPALIVE_NOT_ADVANCING")
    return flags


def summarize(samples: list[dict[str, Any]], worn: bool) -> dict[str, Any]:
    deltas = [sample["delta"] for sample in samples[1:]]
    flags = sorted({flag for sample in samples for flag in sample["flags"]})
    raw_deltas = [delta["whoop.sample.rawNotifications"] for delta in deltas]
    disconnect_deltas = [delta["whoop.link.disconnects"] for delta in deltas]
    hr_continuity_deltas = [delta["whoop.watchdog.hrContinuityCount"] for delta in deltas]
    return {
        "status": "pass" if len(samples) > 1 and not flags else "fail",
        "samples": len(samples),
        "worn_expected": worn,
        "flags": flags,
        "min_raw_notification_delta": min(raw_deltas) if raw_deltas else 0,
        "max_disconnect_delta": max(disconnect_deltas) if disconnect_deltas else 0,
        "max_hr_continuity_delta": max(hr_continuity_deltas) if hr_continuity_deltas else 0,
        "latest": samples[-1]["current"] if samples else {},
    }


def event_outcomes(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    outcomes: list[dict[str, Any]] = []
    by_index = {int(sample["sample"]): sample for sample in samples if "sample" in sample}
    for sample in samples:
        events = sample.get("events") or []
        if not events:
            continue
        sample_index = int(sample["sample"])
        next_sample = by_index.get(sample_index + 1)
        next_delta = next_sample.get("delta", {}) if next_sample else {}
        next_flags = next_sample.get("flags", []) if next_sample else []
        raw_delta = numeric(next_delta.get("whoop.sample.rawNotifications"))
        disconnect_delta = numeric(next_delta.get("whoop.link.disconnects"))
        hr_continuity_delta = numeric(next_delta.get("whoop.watchdog.hrContinuityCount"))
        status = "pending_next_sample"
        if next_sample:
            if raw_delta > 0 and disconnect_delta < 3 and hr_continuity_delta < 3:
                status = "recovered"
            elif "NO_NEW_DATA" in next_flags:
                status = "no_new_data_after_event"
            elif disconnect_delta >= 3 or hr_continuity_delta >= 3:
                status = "churn_after_event"
            else:
                status = "observed"
        outcomes.append({
            "sample": sample_index,
            "events": events,
            "status": status,
            "next_sample": sample_index + 1 if next_sample else None,
            "next_raw_notification_delta": raw_delta,
            "next_accepted_sample_delta": numeric(next_delta.get("whoop.sample.acceptedSamples")),
            "next_disconnect_delta": disconnect_delta,
            "next_hr_continuity_delta": hr_continuity_delta,
            "next_flags": next_flags,
        })
    return outcomes


def parse_key_value_lines(text: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key:
            parsed[key] = value
    return parsed


def compact_pull_state_summary(fields: dict[str, str]) -> dict[str, str]:
    return {key: fields[key] for key in PULL_STATE_SUMMARY_KEYS if key in fields}


def parse_sample_events(values: list[str]) -> dict[int, list[str]]:
    events: dict[int, list[str]] = {}
    for value in values:
        if ":" not in value:
            raise ValueError(f"event must be SAMPLE:LABEL, got {value!r}")
        sample_text, label = value.split(":", 1)
        sample = int(sample_text)
        if sample < 0:
            raise ValueError(f"event sample must be >= 0, got {sample}")
        label = label.strip()
        if not label:
            raise ValueError(f"event label must not be empty, got {value!r}")
        events.setdefault(sample, []).append(label)
    return events


def pull_state_snapshot(device: str, bundle: str, out_dir: Path) -> dict[str, Any]:
    evidence_dir = out_dir / "state"
    result = subprocess.run(
        [
            "./pull_atria_state.sh",
            "--device",
            device,
            "--bundle-id",
            bundle,
            "--evidence-dir",
            str(evidence_dir),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    fields = parse_key_value_lines(result.stdout)
    summary_path = evidence_dir / "pull-summary.txt"
    if summary_path.exists():
        fields.update(parse_key_value_lines(summary_path.read_text(encoding="utf-8", errors="replace")))
    return {
        "status": "ok" if result.returncode == 0 else "failed",
        "exit_code": result.returncode,
        "evidence_dir": str(evidence_dir),
        "summary_file": str(summary_path),
        "fields": compact_pull_state_summary(fields),
    }


def write_audit_snapshot(root: Path, destination: Path) -> dict[str, Any]:
    from tools import audit_realtime_ble_validation as audit

    report = audit.evaluate(root)
    destination.write_text(audit.markdown_summary(report), encoding="utf-8")
    return {
        "status": report.get("status", "missing"),
        "path": str(destination),
        "summary_count": report.get("summary_count", 0),
        "blockers": report.get("blockers", []),
    }


def command_string(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=os.environ.get("ATRIA_DEVICE_ID", DEFAULT_DEVICE))
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE)
    parser.add_argument("--samples", type=int, default=2)
    parser.add_argument("--interval", type=float, default=120)
    parser.add_argument("--label", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    parser.add_argument("--out-dir", type=Path, default=Path("logs/live-device/realtime-ble-monitor"))
    parser.add_argument("--not-worn", action="store_true", help="Do not flag zero contact or rawNotif+0 as failures.")
    parser.add_argument(
        "--pull-state",
        action="store_true",
        help="After the monitor finishes, non-disruptively pull sessions and active journal evidence into the run directory.",
    )
    parser.add_argument(
        "--event",
        action="append",
        default=[],
        metavar="SAMPLE:LABEL",
        help="Annotate a sample index in samples.jsonl/summary.json, e.g. --event 2:brief_contact_loss_reseat.",
    )
    parser.add_argument(
        "--audit-snapshot",
        action="store_true",
        help="After writing summary.json, archive the realtime BLE audit Markdown into this run directory.",
    )
    args = parser.parse_args()

    if args.samples < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 64
    try:
        sample_events = parse_sample_events(args.event)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 64

    out_dir = (Path.cwd() / args.out_dir / args.label).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = out_dir / "samples.jsonl"
    summary_path = out_dir / "summary.json"

    previous: dict[str, Any] | None = None
    samples: list[dict[str, Any]] = []
    for index in range(args.samples):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        prefs_path = out_dir / f"prefs-{index:04d}-{stamp}.plist"
        code, output = copy_preferences(args.device, args.bundle, prefs_path)
        if code != 0:
            sample = {
                "sample": index,
                "captured_at": utc_now(),
                "copy_status": code,
                "copy_output": output.strip(),
                "current": {},
                "delta": {key: 0 for key in COUNTER_KEYS},
                "flags": ["PREFS_COPY_FAILED"],
            }
        else:
            current = read_preferences(prefs_path)
            delta = compute_delta(previous, current)
            flags = [] if previous is None else evaluate_sample(delta, current, worn=not args.not_worn)
            sample = {
                "sample": index,
                "captured_at": utc_now(),
                "copy_status": code,
                "prefs": str(prefs_path),
                "current": current,
                "delta": delta,
                "flags": flags,
            }
            previous = current
        sample_events_for_index = sample_events.get(index, [])
        if sample_events_for_index:
            sample["events"] = sample_events_for_index
        samples.append(sample)
        with jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(sample, sort_keys=True) + "\n")
        print(
            "ATRIA_REALTIME_BLE_SAMPLE "
            f"index={index} rawNotif+{sample['delta']['whoop.sample.rawNotifications']} "
            f"accepted+{sample['delta']['whoop.sample.acceptedSamples']} "
            f"disc+{sample['delta']['whoop.link.disconnects']} "
            f"hrCont+{sample['delta']['whoop.watchdog.hrContinuityCount']} "
            f"keepaliveTicks+{sample['delta']['whoop.keepalive.ticks']} "
            f"sample={sample['current'].get('whoop.sample.lastStatus')} "
            f"lastAction={sample['current'].get('whoop.watchdog.lastAction')} "
            f"keepalive={sample['current'].get('whoop.keepalive.lastAction')} "
            f"keepaliveTicks={sample['current'].get('whoop.keepalive.ticks')} "
            f"events={','.join(sample_events_for_index) or 'none'} "
            f"flags={','.join(sample['flags']) or 'OK'}",
            flush=True,
        )
        if index + 1 < args.samples:
            time.sleep(args.interval)

    summary = summarize(samples, worn=not args.not_worn)
    summary.update({
        "label": args.label,
        "started_at": samples[0]["captured_at"] if samples else utc_now(),
        "finished_at": utc_now(),
        "command": command_string(sys.argv),
        "device": args.device,
        "bundle": args.bundle,
        "jsonl": str(jsonl_path),
        "out_dir": str(out_dir),
        "planned_samples": args.samples,
        "planned_interval_s": args.interval,
        "events": {str(key): value for key, value in sorted(sample_events.items())},
    })
    outcomes = event_outcomes(samples)
    if outcomes:
        summary["event_outcomes"] = outcomes
    if args.pull_state:
        state = pull_state_snapshot(args.device, args.bundle, out_dir)
        summary["state_pull"] = state
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.audit_snapshot:
        audit_root = (Path.cwd() / args.out_dir).resolve()
        summary["audit_snapshot"] = write_audit_snapshot(audit_root, out_dir / "audit.md")
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    state_text = ""
    if "state_pull" in summary:
        state_pull = summary["state_pull"]
        state_fields = state_pull.get("fields", {})
        continuity = state_fields.get("active_journal_continuity_status", "missing")
        latest_points = state_fields.get("latest_session_points", "missing")
        state_text = f" state_pull={state_pull.get('status')} continuity={continuity} latest_points={latest_points}"
    print(
        "ATRIA_REALTIME_BLE_SUMMARY "
        f"status={summary['status']} samples={summary['samples']} "
        f"min_raw_notification_delta={summary['min_raw_notification_delta']} "
        f"max_disconnect_delta={summary['max_disconnect_delta']} "
        f"max_hr_continuity_delta={summary['max_hr_continuity_delta']} "
        f"flags={','.join(summary['flags']) or 'none'} "
        f"summary={summary_path}"
        f"{state_text}",
        flush=True,
    )
    if "audit_snapshot" in summary:
        audit_snapshot = summary["audit_snapshot"]
        print(
            "ATRIA_REALTIME_BLE_AUDIT "
            f"status={audit_snapshot.get('status')} "
            f"summary_count={audit_snapshot.get('summary_count')} "
            f"path={audit_snapshot.get('path')}",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
