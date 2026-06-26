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
    "ATRIADBG_SESSIONS_SUMMARY ",
    "ATRIADBG_ACTIVE_JOURNAL_SEGMENTS_SUMMARY ",
)

PRESETS = {
    "custom": {},
    "overnight": {
        "samples": 11,
        "interval": 60 * 60,
        "min_samples": 9,
        "min_span": 8 * 60 * 60,
        "min_coverage": 85.0,
        "max_gap": 30.0,
        "allowed_thermal": ["nominal", "fair"],
        "max_battery_drop": 35.0,
    },
}


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
            name = "sessions" if prefix.startswith("ATRIADBG_SESSIONS") else "active_journal"
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


def current_git_commit(repo: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        return "missing"
    return result.stdout.strip()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def stamp_run_provenance(final: dict[str, object], repo: Path, monitor_started_at: str) -> None:
    final["monitor_started_at"] = monitor_started_at
    final["monitor_finished_at"] = utc_now()
    final["app_commit"] = current_git_commit(repo)


def value_from(args: argparse.Namespace, name: str) -> object:
    preset = PRESETS.get(args.preset, {})
    value = getattr(args, name)
    return value if value is not None else preset.get(name)


def evaluate_acceptance(final: dict[str, object], args: argparse.Namespace) -> dict[str, object]:
    thermal_states = set(final.get("thermal_states", []))
    allowed_thermal_list = list(value_from(args, "allowed_thermal") or [])
    allowed_thermal = set(allowed_thermal_list)
    max_battery_drop = float(value_from(args, "max_battery_drop") or 0)
    min_samples = int(value_from(args, "min_samples") or 0)
    min_span = float(value_from(args, "min_span") or 0)
    min_coverage = float(value_from(args, "min_coverage") or 0)
    max_gap = float(value_from(args, "max_gap") or 0)
    battery_delta = final.get("battery_delta")
    if not isinstance(battery_delta, (int, float)):
        battery_ok = False
    else:
        battery_ok = battery_delta >= -max_battery_drop
    observed_samples = int(final.get("samples", 0))
    observed_active_ok_samples = int(final.get("active_ok_samples", 0))
    observed_session_span = float(final.get("latest_recent_session_span_s", 0) or 0)
    observed_session_coverage = float(final.get("latest_recent_session_coverage_percent", 0) or 0)
    observed_active_gap = float(final.get("max_active_accepted_gap_s", 0) or 0)
    observed_recent_gap = float(final.get("max_recent_accepted_gap_s", 0) or 0)
    checks = {
        "samples": observed_samples >= min_samples,
        "active_ok_samples": observed_active_ok_samples >= min_samples,
        "session_span": observed_session_span >= min_span,
        "session_coverage": observed_session_coverage >= min_coverage,
        "active_gap": observed_active_gap <= max_gap,
        "recent_gap": observed_recent_gap <= max_gap,
        "thermal": bool(thermal_states) and thermal_states.issubset(allowed_thermal),
        "battery": battery_ok,
    }
    blockers = [name for name, ok in checks.items() if not ok]
    return {
        "acceptance_status": "pass" if not blockers else "fail",
        "acceptance_checks": checks,
        "acceptance_blockers": blockers,
        "acceptance_diagnostics": {
            "samples": {
                "observed": observed_samples,
                "required_min": min_samples,
                "ok": checks["samples"],
            },
            "active_ok_samples": {
                "observed": observed_active_ok_samples,
                "required_min": min_samples,
                "ok": checks["active_ok_samples"],
            },
            "session_span": {
                "observed_s": observed_session_span,
                "required_min_s": min_span,
                "ok": checks["session_span"],
            },
            "session_coverage": {
                "observed_percent": observed_session_coverage,
                "required_min_percent": min_coverage,
                "ok": checks["session_coverage"],
            },
            "active_gap": {
                "observed_s": observed_active_gap,
                "required_max_s": max_gap,
                "ok": checks["active_gap"],
            },
            "recent_gap": {
                "observed_s": observed_recent_gap,
                "required_max_s": max_gap,
                "ok": checks["recent_gap"],
            },
            "thermal": {
                "observed": sorted(thermal_states),
                "allowed": allowed_thermal_list,
                "ok": checks["thermal"],
            },
            "battery": {
                "observed_delta_percent": battery_delta,
                "required_min_delta_percent": -max_battery_drop,
                "ok": checks["battery"],
            },
        },
        "criteria": {
            "preset": args.preset,
            "min_samples": min_samples,
            "min_span_s": min_span,
            "min_coverage_percent": min_coverage,
            "max_gap_s": max_gap,
            "allowed_thermal": allowed_thermal_list,
            "max_battery_drop_percent": max_battery_drop,
        },
    }


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
        "battery_delta": (batteries[-1] - batteries[0]) if batteries else "missing",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default=os.environ.get("ATRIA_DEVICE_ID", ""), help="CoreDevice physical iPhone id.")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Atria repo root.")
    parser.add_argument("--out-dir", type=Path, default=Path("logs/live-device/long-wear-monitor"), help="Directory for pulls and rollups.")
    parser.add_argument("--preset", choices=sorted(PRESETS), default="custom",
                        help="Preset cadence and acceptance criteria. overnight = 11 hourly pulls over 10h.")
    parser.add_argument("--samples", type=int, default=None, help="Number of pull-only samples to collect.")
    parser.add_argument("--interval", type=float, default=None, help="Seconds between samples.")
    parser.add_argument("--label", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"), help="Run label.")
    parser.add_argument("--min-samples", type=int, default=None, help="Minimum successful pull samples required for acceptance.")
    parser.add_argument("--min-span", type=float, default=None, help="Minimum recent persisted-session span in seconds.")
    parser.add_argument("--min-coverage", type=float, default=None, help="Minimum recent persisted-session coverage percent.")
    parser.add_argument("--max-gap", type=float, default=None, help="Maximum accepted-HR gap in seconds.")
    parser.add_argument("--allowed-thermal", nargs="+", default=None, help="Thermal states allowed for acceptance.")
    parser.add_argument("--max-battery-drop", type=float, default=None, help="Maximum allowed battery percentage drop.")
    args = parser.parse_args()
    samples_count = int(value_from(args, "samples") or 2)
    interval_seconds = float(value_from(args, "interval") or 300)

    if not args.device:
        print("Set ATRIA_DEVICE_ID or pass --device.", file=sys.stderr)
        return 64
    if samples_count < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 64
    repo = args.repo.resolve()
    out_root = (repo / args.out_dir / args.label).resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    jsonl_path = out_root / "samples.jsonl"
    summary_path = out_root / "summary.json"
    samples: list[dict[str, object]] = []
    monitor_started_at = utc_now()

    for index in range(samples_count):
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
        if index + 1 < samples_count:
            time.sleep(interval_seconds)

    final = rollup(samples)
    final.update(evaluate_acceptance(final, args))
    final["label"] = args.label
    final["preset"] = args.preset
    final["planned_samples"] = samples_count
    final["planned_interval_s"] = interval_seconds
    final["planned_duration_s"] = max(0, samples_count - 1) * interval_seconds
    stamp_run_provenance(final, repo, monitor_started_at)
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
        f"acceptance_status={final['acceptance_status']} "
        f"acceptance_blockers={','.join(final['acceptance_blockers']) or 'none'} "
        f"summary={summary_path}",
        flush=True,
    )
    return 0 if all(sample.get("returncode") == 0 for sample in samples) else 1


if __name__ == "__main__":
    raise SystemExit(main())
