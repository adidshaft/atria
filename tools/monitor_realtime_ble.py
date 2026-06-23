#!/usr/bin/env python3
"""Non-invasive realtime BLE validation monitor for Atria physical-device runs."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
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
]

STATUS_KEYS = [
    "whoop.sample.lastStatus",
    "whoop.link.lastStatus",
    "whoop.link.lastReason",
    "whoop.watchdog.lastAction",
    "whoop.radio.standardHROnly",
    "whoop.longWear.enabled",
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=os.environ.get("ATRIA_DEVICE_ID", DEFAULT_DEVICE))
    parser.add_argument("--bundle", default=DEFAULT_BUNDLE)
    parser.add_argument("--samples", type=int, default=2)
    parser.add_argument("--interval", type=float, default=120)
    parser.add_argument("--label", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    parser.add_argument("--out-dir", type=Path, default=Path("logs/live-device/realtime-ble-monitor"))
    parser.add_argument("--not-worn", action="store_true", help="Do not flag zero contact or rawNotif+0 as failures.")
    args = parser.parse_args()

    if args.samples < 1:
        print("--samples must be >= 1", file=sys.stderr)
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
            flags = evaluate_sample(delta, current, worn=not args.not_worn)
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
        samples.append(sample)
        with jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(sample, sort_keys=True) + "\n")
        print(
            "ATRIA_REALTIME_BLE_SAMPLE "
            f"index={index} rawNotif+{sample['delta']['whoop.sample.rawNotifications']} "
            f"accepted+{sample['delta']['whoop.sample.acceptedSamples']} "
            f"disc+{sample['delta']['whoop.link.disconnects']} "
            f"hrCont+{sample['delta']['whoop.watchdog.hrContinuityCount']} "
            f"sample={sample['current'].get('whoop.sample.lastStatus')} "
            f"lastAction={sample['current'].get('whoop.watchdog.lastAction')} "
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
        "jsonl": str(jsonl_path),
        "out_dir": str(out_dir),
        "planned_samples": args.samples,
        "planned_interval_s": args.interval,
    })
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "ATRIA_REALTIME_BLE_SUMMARY "
        f"status={summary['status']} samples={summary['samples']} "
        f"min_raw_notification_delta={summary['min_raw_notification_delta']} "
        f"max_disconnect_delta={summary['max_disconnect_delta']} "
        f"max_hr_continuity_delta={summary['max_hr_continuity_delta']} "
        f"flags={','.join(summary['flags']) or 'none'} "
        f"summary={summary_path}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
