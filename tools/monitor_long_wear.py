#!/usr/bin/env python3
"""Non-invasive long-wear evidence monitor for Atria physical-device runs."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


SUMMARY_PREFIXES = (
    "WHOOPDBG_SESSIONS_SUMMARY ",
    "WHOOPDBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY ",
)


def parse_tokens(line: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in line.split():
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        parsed[key] = value
    return parsed


def coerce(value: str) -> object:
    if value in {"ok", "empty", "missing", "decode_error"}:
        return value
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+[.]\d+", value):
        return float(value)
    return value


def parsed_summary(output: str) -> dict[str, dict[str, object]]:
    summaries: dict[str, dict[str, object]] = {}
    for raw_line in output.splitlines():
        line = raw_line.strip()
        for prefix in SUMMARY_PREFIXES:
            if not line.startswith(prefix):
                continue
            name = "sessions" if prefix.startswith("WHOOPDBG_SESSIONS") else "active_journal"
            summaries[name] = {key: coerce(value) for key, value in parse_tokens(line).items()}
    return summaries


def run_pull(repo: Path, device_id: str, out_dir: Path, log_path: Path) -> tuple[int, str]:
    env = os.environ.copy()
    env["ATRIA_DEVICE_ID"] = device_id
    command = [
        str(repo / "live_device_debug.sh"),
        "--pull-only",
        "--pull-sessions",
        str(out_dir),
        "--log",
        str(log_path),
    ]
    result = subprocess.run(
        command,
        cwd=repo,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return result.returncode, result.stdout


def rollup(samples: list[dict[str, object]]) -> dict[str, object]:
    active_samples = [item.get("active_journal", {}) for item in samples if isinstance(item.get("active_journal"), dict)]
    session_samples = [item.get("sessions", {}) for item in samples if isinstance(item.get("sessions"), dict)]
    statuses = [item.get("status") for item in active_samples]
    ok_active = [item for item in active_samples if item.get("status") == "ok"]
    ok_sessions = [item for item in session_samples if item.get("status") == "ok"]
    thermal_states = sorted({str(item.get("thermal", "missing")) for item in ok_active})
    power_modes = sorted({str(item.get("power_mode", "missing")) for item in ok_active})
    batteries = [
        item.get("battery")
        for item in ok_active
        if isinstance(item.get("battery"), int) and int(item["battery"]) >= 0
    ]
    return {
        "status": "ok" if samples else "empty",
        "samples": len(samples),
        "active_ok_samples": len(ok_active),
        "active_statuses": statuses,
        "latest_active_duration_s": ok_active[-1].get("duration_s") if ok_active else 0,
        "latest_active_hr_samples": ok_active[-1].get("delta_samples") if ok_active else 0,
        "latest_active_rr_samples": ok_active[-1].get("delta_rr") if ok_active else 0,
        "max_active_raw_gap_s": max((float(item.get("max_raw_gap_s", 0) or 0) for item in ok_active), default=0.0),
        "max_active_accepted_gap_s": max((float(item.get("max_accepted_gap_s", 0) or 0) for item in ok_active), default=0.0),
        "latest_recent_session_span_s": ok_sessions[-1].get("recent_span_s") if ok_sessions else 0,
        "latest_recent_session_coverage_percent": ok_sessions[-1].get("recent_coverage_percent") if ok_sessions else 0,
        "latest_recent_session_samples": ok_sessions[-1].get("recent_samples") if ok_sessions else 0,
        "latest_recent_session_rr": ok_sessions[-1].get("recent_rr") if ok_sessions else 0,
        "max_recent_raw_gap_s": max((float(item.get("recent_max_raw_gap_s", 0) or 0) for item in ok_sessions), default=0.0),
        "max_recent_accepted_gap_s": max((float(item.get("recent_max_accepted_gap_s", 0) or 0) for item in ok_sessions), default=0.0),
        "thermal_states": thermal_states,
        "power_modes": power_modes,
        "battery_first": batteries[0] if batteries else "missing",
        "battery_latest": batteries[-1] if batteries else "missing",
        "battery_delta": (batteries[-1] - batteries[0]) if len(batteries) >= 2 else "missing",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=os.environ.get("ATRIA_DEVICE_ID", ""), help="CoreDevice physical iPhone id.")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Atria repo root.")
    parser.add_argument("--out-dir", type=Path, default=Path("logs/live-device/long-wear-monitor"), help="Directory for pulls and rollups.")
    parser.add_argument("--samples", type=int, default=2, help="Number of pull-only samples to collect.")
    parser.add_argument("--interval", type=float, default=300, help="Seconds between samples.")
    parser.add_argument("--label", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"), help="Run label.")
    args = parser.parse_args()

    if not args.device:
        print("Set ATRIA_DEVICE_ID or pass --device.", file=sys.stderr)
        return 64
    if args.samples < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 64
    repo = args.repo.resolve()
    out_root = (repo / args.out_dir / args.label).resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    jsonl_path = out_root / "samples.jsonl"
    summary_path = out_root / "summary.json"
    samples: list[dict[str, object]] = []

    for index in range(args.samples):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        pull_dir = out_root / f"pull-{index:04d}-{stamp}"
        log_path = out_root / f"pull-{index:04d}-{stamp}.log"
        code, output = run_pull(repo, args.device, pull_dir, log_path)
        item: dict[str, object] = {
            "sample": index,
            "captured_at": stamp,
            "returncode": code,
            "pull_dir": str(pull_dir),
            "log": str(log_path),
            **parsed_summary(output),
        }
        samples.append(item)
        with jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(item, sort_keys=True) + "\n")
        active = item.get("active_journal", {})
        sessions = item.get("sessions", {})
        active_status = active.get("status", "missing") if isinstance(active, dict) else "missing"
        session_status = sessions.get("status", "missing") if isinstance(sessions, dict) else "missing"
        print(
            "ATRIA_LONG_WEAR_MONITOR_SAMPLE "
            f"index={index} returncode={code} active_status={active_status} sessions_status={session_status}",
            flush=True,
        )
        if code != 0:
            break
        if index + 1 < args.samples:
            time.sleep(args.interval)

    final = rollup(samples)
    final["label"] = args.label
    final["out_dir"] = str(out_root)
    final["jsonl"] = str(jsonl_path)
    summary_path.write_text(json.dumps(final, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "ATRIA_LONG_WEAR_MONITOR_SUMMARY "
        f"status={final['status']} samples={final['samples']} "
        f"active_ok_samples={final['active_ok_samples']} "
        f"latest_active_duration_s={final['latest_active_duration_s']} "
        f"latest_recent_session_span_s={final['latest_recent_session_span_s']} "
        f"latest_recent_session_coverage_percent={final['latest_recent_session_coverage_percent']} "
        f"thermal_states={','.join(final['thermal_states'])} "
        f"battery_first={final['battery_first']} battery_latest={final['battery_latest']} "
        f"summary={summary_path}",
        flush=True,
    )
    return 0 if all(sample.get("returncode") == 0 for sample in samples) else 1


if __name__ == "__main__":
    raise SystemExit(main())
