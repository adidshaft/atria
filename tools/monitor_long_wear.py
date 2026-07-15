#!/usr/bin/env python3
"""Non-invasive long-wear evidence monitor for Atria physical-device runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


APPLE_REFERENCE_UNIX_OFFSET = 978_307_200.0
RECENT_ATTRIBUTED_WINDOW_SECONDS = 60 * 60

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


def parsed_utc_timestamp(value: str) -> float:
    """Parse monitor ISO/compact UTC stamps to Unix seconds."""
    if re.fullmatch(r"\d{8}T\d{6}Z", value):
        return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def apple_reference_seconds(unix_seconds: float) -> float:
    return unix_seconds - APPLE_REFERENCE_UNIX_OFFSET


def attributed_timeline(timestamps: list[float],
                        *,
                        window_start: float,
                        window_end: float,
                        max_gap: float,
                        source_files: int,
                        malformed: int = 0,
                        future: int = 0) -> dict[str, object]:
    """Project immutable accepted-HR timestamps onto one monitor-owned window.

    Leading and trailing silence remain part of coverage and max-gap evidence;
    clipping must never make an incomplete run look continuous. Duplicate
    timestamps from overlapping checkpoint sessions are collapsed.
    """
    observation_span = max(0.0, window_end - window_start)
    retained = sorted({stamp for stamp in timestamps if window_start <= stamp <= window_end})
    if not retained or observation_span <= 0:
        return {
            "status": "empty",
            "window_start_apple_s": window_start,
            "window_end_apple_s": window_end,
            "observation_span_s": observation_span,
            "evidence_span_s": 0.0,
            "coverage_percent": 0.0,
            "samples": 0,
            "max_accepted_gap_s": 0.0,
            "boundary_start_gap_s": observation_span,
            "boundary_end_gap_s": observation_span,
            "source_files": source_files,
            "malformed_timestamps": malformed,
            "future_timestamps": future,
        }
    boundaries = [window_start, *retained, window_end]
    deltas = [max(0.0, current - previous)
              for previous, current in zip(boundaries, boundaries[1:])]
    safe_gap = max(0.0, max_gap)
    covered = sum(delta for delta in deltas if delta <= safe_gap)
    return {
        "status": "ok",
        "window_start_apple_s": window_start,
        "window_end_apple_s": window_end,
        "observation_span_s": observation_span,
        "evidence_span_s": max(0.0, retained[-1] - retained[0]),
        "coverage_percent": min(100.0, max(0.0, covered / observation_span * 100)),
        "samples": len(retained),
        "max_accepted_gap_s": max(deltas, default=0.0),
        "boundary_start_gap_s": max(0.0, retained[0] - window_start),
        "boundary_end_gap_s": max(0.0, window_end - retained[-1]),
        "source_files": source_files,
        "malformed_timestamps": malformed,
        "future_timestamps": future,
    }


def session_timestamps(path: Path, *, window_end: float) -> tuple[list[float], set[str], set[str], set[str]]:
    source_ids = {"sessions.json"} if path.is_file() else set()
    malformed_ids: set[str] = set()
    future_ids: set[str] = set()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        if path.is_file():
            malformed_ids.add("sessions.json:decode")
        return [], source_ids, malformed_ids, future_ids
    if isinstance(payload, list):
        sessions = payload
    elif isinstance(payload, dict) and isinstance(payload.get("sessions"), list):
        sessions = payload["sessions"]
    else:
        malformed_ids.add("sessions.json:shape")
        return [], source_ids, malformed_ids, future_ids
    timestamps: list[float] = []
    for session_index, session in enumerate(sessions):
        session_key = (str(session.get("id")) if isinstance(session, dict) and session.get("id")
                       else f"index-{session_index}")
        if not isinstance(session, dict) or not isinstance(session.get("start"), (int, float)):
            malformed_ids.add(f"sessions.json:{session_key}:session")
            continue
        start = float(session["start"])
        points = session.get("points")
        if not isinstance(points, list):
            malformed_ids.add(f"sessions.json:{session_key}:points-shape")
            continue
        for point_index, point in enumerate(points):
            if not isinstance(point, dict) or not isinstance(point.get("t"), (int, float)):
                malformed_ids.add(f"sessions.json:{session_key}:point-{point_index}")
                continue
            stamp = start + float(point["t"])
            if stamp > window_end:
                future_ids.add(f"sessions.json:{session_key}:point-{point_index}:{stamp:.9f}")
            else:
                timestamps.append(stamp)
    return timestamps, source_ids, malformed_ids, future_ids


def active_journal_timestamps(directory: Path,
                              *,
                              window_end: float) -> tuple[list[float], set[str], set[str], set[str]]:
    timestamps: list[float] = []
    source_ids: set[str] = set()
    malformed_ids: set[str] = set()
    future_ids: set[str] = set()
    for path in sorted(directory.glob("segment-*.json")):
        try:
            segment = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            source_id = f"active:{path.name}"
            source_ids.add(source_id)
            malformed_ids.add(f"{source_id}:decode")
            continue
        record_id = segment.get("id") if isinstance(segment, dict) else None
        sequence = segment.get("sequence") if isinstance(segment, dict) else None
        source_id = f"active:{record_id}:{sequence}" if record_id is not None else f"active:{path.name}"
        source_ids.add(source_id)
        samples = segment.get("samples") if isinstance(segment, dict) else None
        if not isinstance(samples, list):
            malformed_ids.add(f"{source_id}:shape")
            continue
        for sample_index, sample in enumerate(samples):
            if not isinstance(sample, dict) or not isinstance(sample.get("t"), (int, float)):
                malformed_ids.add(f"{source_id}:sample-{sample_index}")
                continue
            stamp = float(sample["t"])
            if stamp > window_end:
                future_ids.add(f"{source_id}:sample-{sample_index}:{stamp:.9f}")
            else:
                timestamps.append(stamp)
    return timestamps, source_ids, malformed_ids, future_ids


def project_run_attributed_evidence(pull_dir: Path,
                                    monitor_started_at: str,
                                    captured_at: str,
                                    max_gap: float,
                                    cumulative: dict[str, object] | None = None
                                    ) -> dict[str, dict[str, object]]:
    window_start = apple_reference_seconds(parsed_utc_timestamp(monitor_started_at))
    window_end = apple_reference_seconds(parsed_utc_timestamp(captured_at))
    sessions_path = pull_dir / "sessions.json"
    session_values, session_sources, session_bad_ids, session_future_ids = session_timestamps(
        sessions_path,
        window_end=window_end,
    )
    active_values, active_sources, active_bad_ids, active_future_ids = active_journal_timestamps(
        pull_dir / "atria-active-session.segments",
        window_end=window_end,
    )
    if cumulative is not None:
        session_union = cumulative.setdefault("session_timestamps", set())
        active_union = cumulative.setdefault("active_timestamps", set())
        if not isinstance(session_union, set) or not isinstance(active_union, set):
            raise ValueError("malformed cumulative attributed-evidence state")
        session_union.update(session_values)
        active_union.update(active_values)
        session_values = list(session_union)
        active_values = list(active_union)
        for key, values in (
            ("session_sources", session_sources), ("session_malformed_ids", session_bad_ids),
            ("session_future_ids", session_future_ids), ("active_sources", active_sources),
            ("active_malformed_ids", active_bad_ids), ("active_future_ids", active_future_ids),
        ):
            union = cumulative.setdefault(key, set())
            if not isinstance(union, set):
                raise ValueError("malformed cumulative attributed-evidence diagnostics")
            union.update(values)
        session_sources = cumulative["session_sources"]
        session_bad_ids = cumulative["session_malformed_ids"]
        session_future_ids = cumulative["session_future_ids"]
        active_sources = cumulative["active_sources"]
        active_bad_ids = cumulative["active_malformed_ids"]
        active_future_ids = cumulative["active_future_ids"]
    session_files, session_bad, session_future = map(len, (session_sources, session_bad_ids, session_future_ids))
    active_files, active_bad, active_future = map(len, (active_sources, active_bad_ids, active_future_ids))
    recent_window_start = max(window_start, window_end - RECENT_ATTRIBUTED_WINDOW_SECONDS)
    return {
        "run_attributed_sessions": attributed_timeline(
            session_values,
            window_start=window_start,
            window_end=window_end,
            max_gap=max_gap,
            source_files=session_files,
            malformed=session_bad,
            future=session_future,
        ),
        "run_attributed_active_journal": attributed_timeline(
            active_values,
            window_start=window_start,
            window_end=window_end,
            max_gap=max_gap,
            source_files=active_files,
            malformed=active_bad,
            future=active_future,
        ),
        "run_attributed_durable_union": attributed_timeline(
            [*session_values, *active_values],
            window_start=window_start,
            window_end=window_end,
            max_gap=max_gap,
            source_files=session_files + active_files,
            malformed=session_bad + active_bad,
            future=session_future + active_future,
        ),
        "run_attributed_durable_union_recent": attributed_timeline(
            [*session_values, *active_values],
            window_start=recent_window_start,
            window_end=window_end,
            max_gap=max_gap,
            source_files=session_files + active_files,
            malformed=session_bad + active_bad,
            future=session_future + active_future,
        ),
    }


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


def launchctl_label(label: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
    return f"com.adidshaft.atria.longwear.{safe or 'run'}"


def detached_command(repo: Path, args: argparse.Namespace, log_path: Path) -> list[str]:
    command = [
        sys.executable,
        str((repo / "tools" / "monitor_long_wear.py").resolve()),
        "--repo",
        str(repo),
        "--device",
        args.device,
        "--out-dir",
        str(args.out_dir),
        "--preset",
        args.preset,
        "--label",
        args.label,
    ]
    optional_args: tuple[tuple[str, str], ...] = (
        ("samples", "--samples"),
        ("interval", "--interval"),
        ("min_samples", "--min-samples"),
        ("min_span", "--min-span"),
        ("min_coverage", "--min-coverage"),
        ("max_gap", "--max-gap"),
        ("max_battery_drop", "--max-battery-drop"),
        ("app_commit", "--app-commit"),
    )
    for attribute, flag in optional_args:
        value = getattr(args, attribute)
        if value is not None:
            command.extend([flag, str(value)])
    if args.allowed_thermal is not None:
        command.append("--allowed-thermal")
        command.extend(str(value) for value in args.allowed_thermal)

    quoted = " ".join(shlex.quote(part) for part in command)
    job_label = launchctl_label(args.label)
    # `launchctl submit` may infer KeepAlive for a submitted executable. Do not
    # `exec` away this wrapper: its EXIT trap removes the one-shot job after the
    # monitor flushes its summary, preventing an automatic second invocation.
    shell = (
        f"cd {shlex.quote(str(repo))} || exit 70; "
        f"trap 'launchctl remove {job_label} >/dev/null 2>&1 || true' EXIT; "
        f"{quoted} >> {shlex.quote(str(log_path))} 2>&1"
    )
    return ["launchctl", "submit", "-l", job_label, "--", "/bin/zsh", "-lc", shell]


def submit_detached(repo: Path, args: argparse.Namespace) -> tuple[str, Path]:
    out_root = (repo / args.out_dir).resolve()
    out_root.mkdir(parents=True, exist_ok=True)
    log_path = out_root / f"{args.label}.out"
    subprocess.run(detached_command(repo, args, log_path), cwd=repo, check=True)
    return launchctl_label(args.label), log_path


def prepare_fresh_run_directory(path: Path) -> None:
    """Create a live-run directory without ever reusing recorded evidence."""
    if path.exists():
        if not path.is_dir():
            raise FileExistsError(f"monitor output path is not a directory: {path}")
        if next(path.iterdir(), None) is not None:
            raise FileExistsError(f"monitor output directory is not empty: {path}")
        return
    path.mkdir(parents=True, exist_ok=False)


def write_run_metadata(path: Path,
                       repo: Path,
                       args: argparse.Namespace,
                       *,
                       samples_count: int,
                       interval_seconds: float,
                       monitor_started_at: str) -> None:
    data = {
        "label": args.label,
        "preset": args.preset,
        "planned_samples": samples_count,
        "planned_interval_s": interval_seconds,
        "planned_duration_s": max(0, samples_count - 1) * interval_seconds,
        "app_commit": (args.app_commit or current_git_commit(repo)).strip() or "missing",
        "monitor_commit": current_git_commit(repo),
        "monitor_started_at": monitor_started_at,
        "criteria": {
            "min_samples": int(value_from(args, "min_samples") or 0),
            "min_span_s": float(value_from(args, "min_span") or 0),
            "min_coverage_percent": float(value_from(args, "min_coverage") or 0),
            "max_gap_s": float(value_from(args, "max_gap") or 0),
            "allowed_thermal": list(value_from(args, "allowed_thermal") or []),
            "max_battery_drop_percent": float(value_from(args, "max_battery_drop") or 0),
        },
    }
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def stamp_run_provenance(final: dict[str, object],
                         repo: Path,
                         monitor_started_at: str,
                         app_commit: str | None = None) -> None:
    final["monitor_started_at"] = monitor_started_at
    final["monitor_finished_at"] = utc_now()
    final["app_commit"] = (app_commit or current_git_commit(repo)).strip() or "missing"
    final["monitor_commit"] = current_git_commit(repo)


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
    attributed_sessions_status = final.get("latest_attributed_session_status")
    attributed_active_status = final.get("latest_attributed_active_status")
    observed_active_ok_samples = int(final.get("attributed_active_ok_samples", 0))
    durable_union_status = final.get("latest_attributed_durable_union_status")
    observed_session_span = float(final.get("latest_attributed_durable_union_observation_span_s", 0) or 0)
    observed_session_coverage = float(final.get("latest_attributed_durable_union_coverage_percent", 0) or 0)
    observed_active_gap = float(final.get("max_attributed_durable_union_accepted_gap_s", 0) or 0)
    recent_gap_value = final.get("latest_attributed_durable_union_recent_max_accepted_gap_s")
    recent_gap_window = final.get("latest_attributed_durable_union_recent_observation_span_s")
    if isinstance(recent_gap_value, (int, float)):
        observed_recent_gap = float(recent_gap_value)
        recent_gap_source = "latest_attributed_durable_union_recent"
    else:
        # Fail-safe for summaries produced before the explicit window existed:
        # never let missing recent evidence erase a known whole-run gap.
        observed_recent_gap = observed_active_gap
        recent_gap_source = "whole_run_fallback_missing_recent_window"
    attributed_evidence_ok = (attributed_sessions_status == "ok"
                              and attributed_active_status == "ok"
                              and durable_union_status == "ok")
    checks = {
        "samples": observed_samples >= min_samples,
        "attributed_evidence": attributed_evidence_ok,
        "active_ok_samples": (attributed_active_status == "ok"
                              and observed_active_ok_samples >= min_samples),
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
            "attributed_evidence": {
                "sessions_status": attributed_sessions_status or "missing",
                "active_status": attributed_active_status or "missing",
                "durable_union_status": durable_union_status or "missing",
                "ok": checks["attributed_evidence"],
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
                "window_s": recent_gap_window if isinstance(recent_gap_window, (int, float)) else "missing",
                "configured_window_s": RECENT_ATTRIBUTED_WINDOW_SECONDS,
                "source": recent_gap_source,
                "scope": "recent_diagnostic_only; active_gap preserves the whole-run maximum",
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


def numeric_series(samples: list[dict[str, object]], section: str, key: str) -> list[float]:
    values: list[float] = []
    for item in samples:
        source = item.get(section, {})
        if not isinstance(source, dict):
            continue
        value = source.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def nondecreasing(values: list[float]) -> bool:
    return all(current >= previous for previous, current in zip(values, values[1:]))


def trend_summary(samples: list[dict[str, object]]) -> dict[str, object]:
    active_duration = numeric_series(samples, "active_journal", "duration_s")
    active_hr = numeric_series(samples, "active_journal", "delta_samples")
    active_rr = numeric_series(samples, "active_journal", "delta_rr")
    batteries = numeric_series(samples, "active_journal", "battery")
    return {
        "active_duration_series_s": active_duration,
        "active_hr_series": active_hr,
        "active_rr_series": active_rr,
        "battery_series": batteries,
        "active_duration_nondecreasing": nondecreasing(active_duration),
        "active_hr_nondecreasing": nondecreasing(active_hr),
        "active_rr_nondecreasing": nondecreasing(active_rr),
        "battery_drop_from_first_percent": (batteries[-1] - batteries[0]) if batteries else "missing",
    }


def rollup(samples: list[dict[str, object]]) -> dict[str, object]:
    active_samples = [item.get("active_journal", {}) for item in samples if isinstance(item.get("active_journal"), dict)]
    session_samples = [item.get("sessions", {}) for item in samples if isinstance(item.get("sessions"), dict)]
    statuses = [item.get("status") for item in active_samples]
    ok_active = [item for item in active_samples if item.get("status") == "ok"]
    ok_sessions = [item for item in session_samples if item.get("status") == "ok"]
    attributed_sessions = [item.get("run_attributed_sessions", {}) for item in samples
                           if isinstance(item.get("run_attributed_sessions"), dict)]
    attributed_active = [item.get("run_attributed_active_journal", {}) for item in samples
                         if isinstance(item.get("run_attributed_active_journal"), dict)]
    attributed_union = [item.get("run_attributed_durable_union", {}) for item in samples
                        if isinstance(item.get("run_attributed_durable_union"), dict)]
    attributed_recent_union = [item.get("run_attributed_durable_union_recent", {}) for item in samples
                               if isinstance(item.get("run_attributed_durable_union_recent"), dict)]
    ok_attributed_sessions = [item for item in attributed_sessions if item.get("status") == "ok"]
    ok_attributed_active = [item for item in attributed_active if item.get("status") == "ok"]
    ok_attributed_union = [item for item in attributed_union if item.get("status") == "ok"]
    ok_attributed_recent_union = [item for item in attributed_recent_union if item.get("status") == "ok"]
    thermal_states = sorted({str(item.get("thermal", "missing")) for item in ok_active})
    power_modes = sorted({str(item.get("power_mode", "missing")) for item in ok_active})
    batteries = [
        item.get("battery")
        for item in ok_active
        if isinstance(item.get("battery"), int) and int(item["battery"]) >= 0
    ]
    final = {
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
        # Acceptance-owned evidence. The legacy recent/cumulative fields above
        # remain visible for diagnostics but are never allowed to gate this run.
        "latest_attributed_session_status": (attributed_sessions[-1].get("status")
                                               if attributed_sessions else "missing"),
        "latest_attributed_active_status": (attributed_active[-1].get("status")
                                              if attributed_active else "missing"),
        "latest_attributed_durable_union_status": (attributed_union[-1].get("status")
                                                     if attributed_union else "missing"),
        "attributed_active_ok_samples": len(ok_attributed_active),
        "latest_attributed_session_observation_span_s": (
            ok_attributed_sessions[-1].get("observation_span_s") if ok_attributed_sessions else 0
        ),
        "latest_attributed_session_evidence_span_s": (
            ok_attributed_sessions[-1].get("evidence_span_s") if ok_attributed_sessions else 0
        ),
        "latest_attributed_session_coverage_percent": (
            ok_attributed_sessions[-1].get("coverage_percent") if ok_attributed_sessions else 0
        ),
        "latest_attributed_session_samples": (
            ok_attributed_sessions[-1].get("samples") if ok_attributed_sessions else 0
        ),
        "max_attributed_session_accepted_gap_s": max(
            (float(item.get("max_accepted_gap_s", 0) or 0) for item in ok_attributed_sessions),
            default=0.0,
        ),
        "max_attributed_active_accepted_gap_s": max(
            (float(item.get("max_accepted_gap_s", 0) or 0) for item in ok_attributed_active),
            default=0.0,
        ),
        "latest_attributed_durable_union_observation_span_s": (
            ok_attributed_union[-1].get("observation_span_s") if ok_attributed_union else 0
        ),
        "latest_attributed_durable_union_coverage_percent": (
            ok_attributed_union[-1].get("coverage_percent") if ok_attributed_union else 0
        ),
        "latest_attributed_durable_union_samples": (
            ok_attributed_union[-1].get("samples") if ok_attributed_union else 0
        ),
        "max_attributed_durable_union_accepted_gap_s": max(
            (float(item.get("max_accepted_gap_s", 0) or 0) for item in ok_attributed_union),
            default=0.0,
        ),
        "latest_attributed_durable_union_recent_observation_span_s": (
            ok_attributed_recent_union[-1].get("observation_span_s") if ok_attributed_recent_union else 0
        ),
        "latest_attributed_durable_union_recent_coverage_percent": (
            ok_attributed_recent_union[-1].get("coverage_percent") if ok_attributed_recent_union else 0
        ),
        "latest_attributed_durable_union_recent_max_accepted_gap_s": (
            ok_attributed_recent_union[-1].get("max_accepted_gap_s")
            if ok_attributed_recent_union else None
        ),
        "thermal_states": thermal_states,
        "power_modes": power_modes,
        "battery_first": batteries[0] if batteries else "missing",
        "battery_latest": batteries[-1] if batteries else "missing",
        "battery_delta": (batteries[-1] - batteries[0]) if batteries else "missing",
    }
    final.update(trend_summary(samples))
    return final


def atomic_write_json(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def atomic_write_jsonl(path: Path, values: list[dict[str, object]]) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text("".join(json.dumps(value, sort_keys=True) + "\n" for value in values),
                         encoding="utf-8")
    temporary.replace(path)


def completed_summary(samples: list[dict[str, object]],
                      args: argparse.Namespace,
                      *,
                      repo: Path,
                      out_root: Path,
                      monitor_started_at: str,
                      app_commit: str | None,
                      planned_samples: int,
                      interval_seconds: float) -> dict[str, object]:
    final = rollup(samples)
    final.update(evaluate_acceptance(final, args))
    final["label"] = args.label
    final["preset"] = args.preset
    final["planned_samples"] = planned_samples
    final["planned_interval_s"] = interval_seconds
    final["planned_duration_s"] = max(0, planned_samples - 1) * interval_seconds
    stamp_run_provenance(final, repo, monitor_started_at, app_commit)
    final["out_dir"] = str(out_root)
    final["jsonl"] = str(out_root / "samples.jsonl")
    return final


def apply_metadata_criteria(args: argparse.Namespace, metadata: dict[str, object]) -> None:
    preset = metadata.get("preset")
    if isinstance(preset, str) and preset in PRESETS:
        args.preset = preset
    criteria = metadata.get("criteria")
    if not isinstance(criteria, dict):
        return
    mapping = {
        "min_samples": "min_samples",
        "min_span_s": "min_span",
        "min_coverage_percent": "min_coverage",
        "max_gap_s": "max_gap",
        "allowed_thermal": "allowed_thermal",
        "max_battery_drop_percent": "max_battery_drop",
    }
    for key, attribute in mapping.items():
        if getattr(args, attribute) is None and key in criteria:
            setattr(args, attribute, criteria[key])


def select_primary_sample_sequence(
    samples: list[dict[str, object]],
    planned_samples: int,
) -> tuple[list[tuple[int, dict[str, object]]], dict[str, object]]:
    """Select one monitor invocation without erasing appended restart evidence.

    A monitor invocation emits zero-based, strictly increasing sample numbers.
    Reusing an output directory can append another ``sample == 0`` after the
    original invocation.  Acceptance must use exactly one invocation rather
    than combining both.  Prefer a complete planned sequence, then the longest
    sequence, then the earliest source record so selection is deterministic.
    """
    safe_planned = max(1, planned_samples)
    parsed: list[tuple[int, dict[str, object], int, float]] = []
    invalid: dict[int, str] = {}
    for source_line, item in enumerate(samples, start=1):
        sample_index = item.get("sample")
        captured_at = item.get("captured_at")
        if not isinstance(sample_index, int) or isinstance(sample_index, bool) or sample_index < 0:
            invalid[source_line] = "invalid_sample_index"
            continue
        if not isinstance(captured_at, str):
            invalid[source_line] = "invalid_captured_at"
            continue
        try:
            captured_seconds = parsed_utc_timestamp(captured_at)
        except (TypeError, ValueError):
            invalid[source_line] = "invalid_captured_at"
            continue
        parsed.append((source_line, item, sample_index, captured_seconds))

    candidates: list[list[tuple[int, dict[str, object], int, float]]] = []
    position = 0
    while position < len(parsed):
        source_line, _, sample_index, _ = parsed[position]
        if sample_index != 0:
            position += 1
            continue
        candidate = [parsed[position]]
        position += 1
        while position < len(parsed) and len(candidate) < safe_planned:
            following = parsed[position]
            expected_index = candidate[-1][2] + 1
            if (following[0] != candidate[-1][0] + 1
                    or following[2] != expected_index
                    or following[3] <= candidate[-1][3]):
                break
            candidate.append(following)
            position += 1
        candidates.append(candidate)

    if not candidates:
        raise ValueError("samples contain no zero-based monitor sequence")
    selected_ordinal, selected = max(
        enumerate(candidates),
        key=lambda entry: (
            len(entry[1]) >= safe_planned,
            min(len(entry[1]), safe_planned),
            -entry[1][0][0],
        ),
    )
    selected = selected[:safe_planned]
    selected_lines = {entry[0] for entry in selected}
    selected_last_line = selected[-1][0]
    excluded: list[dict[str, object]] = []
    for source_line, item in enumerate(samples, start=1):
        if source_line in selected_lines:
            continue
        reason = invalid.get(source_line)
        if reason is None:
            sample_index = item.get("sample")
            if sample_index == 0 and source_line > selected_last_line:
                reason = "later_sequence_reset"
            else:
                reason = "non_primary_sequence"
        excluded.append({
            "source_line": source_line,
            "sample": item.get("sample", "missing"),
            "captured_at": item.get("captured_at", "missing"),
            "pull_dir": item.get("pull_dir", "missing"),
            "reason": reason,
        })
    audit = {
        "source_sample_records": len(samples),
        "detected_sequences": len(candidates),
        "selected_sequence_ordinal": selected_ordinal,
        "selected_sample_records": len(selected),
        "selected_source_lines": [entry[0] for entry in selected],
        "selected_sample_indices": [entry[2] for entry in selected],
        "selected_first_captured_at": selected[0][1]["captured_at"],
        "selected_last_captured_at": selected[-1][1]["captured_at"],
        "excluded_sample_records": len(excluded),
        "excluded_records": excluded,
        "selection_rule": "complete_planned_then_longest_then_earliest_zero_based_monotonic_sequence",
    }
    return [(entry[0], entry[1]) for entry in selected], audit


def effective_monitor_start(metadata_started_at: object,
                            selected_first_captured_at: str) -> tuple[str, str]:
    """Return a defensible observation start when run.json was overwritten."""
    first_seconds = parsed_utc_timestamp(selected_first_captured_at)
    if isinstance(metadata_started_at, str):
        try:
            metadata_seconds = parsed_utc_timestamp(metadata_started_at)
        except (TypeError, ValueError):
            metadata_seconds = None
        if (metadata_seconds is not None
                and 0 <= first_seconds - metadata_seconds <= 300):
            return metadata_started_at, "run_metadata_consistent_with_primary_sequence"
        if metadata_seconds is not None and metadata_seconds > first_seconds:
            return selected_first_captured_at, "primary_first_capture_metadata_after_primary_sequence"
    return selected_first_captured_at, "primary_first_capture_metadata_not_attributable"


def recompute_existing_run(repo: Path,
                           run_dir: Path,
                           args: argparse.Namespace) -> int:
    """Re-evaluate evidence without changing source samples or device pulls."""
    metadata_path = run_dir / "run.json"
    jsonl_path = run_dir / "samples.jsonl"
    recomputed_jsonl_path = run_dir / "recomputed-samples.jsonl"
    summary_path = run_dir / "summary.json"
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        source_jsonl = jsonl_path.read_bytes()
        samples = [json.loads(line) for line in source_jsonl.decode("utf-8").splitlines()
                   if line.strip()]
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"Cannot recompute run: {error}", file=sys.stderr)
        return 66
    if not isinstance(metadata, dict) or not all(isinstance(item, dict) for item in samples):
        print("Cannot recompute run: malformed monitor metadata or samples.", file=sys.stderr)
        return 66
    apply_metadata_criteria(args, metadata)
    args.label = str(metadata.get("label") or run_dir.name)
    max_gap = float(value_from(args, "max_gap") or 0)
    planned_samples = int(metadata.get("planned_samples") or len(samples))
    try:
        selected, selection_audit = select_primary_sample_sequence(samples, planned_samples)
        monitor_started_at, start_source = effective_monitor_start(
            metadata.get("monitor_started_at"),
            str(selection_audit["selected_first_captured_at"]),
        )
    except (TypeError, ValueError) as error:
        print(f"Cannot recompute run: {error}", file=sys.stderr)
        return 66
    projected: list[dict[str, object]] = []
    cumulative: dict[str, object] = {}
    try:
        for _, original in selected:
            item = dict(original)
            pull_dir_value = item.get("pull_dir")
            captured_at = item.get("captured_at")
            if not isinstance(pull_dir_value, str) or not isinstance(captured_at, str):
                raise ValueError("sample lacks pull_dir or captured_at")
            pull_dir = Path(pull_dir_value)
            if not pull_dir.is_absolute():
                pull_dir = (repo / pull_dir).resolve()
            item.update(project_run_attributed_evidence(pull_dir,
                                                        monitor_started_at,
                                                        captured_at,
                                                        max_gap,
                                                        cumulative=cumulative))
            projected.append(item)
    except (OSError, ValueError) as error:
        print(f"Cannot recompute run: {error}", file=sys.stderr)
        return 66

    interval_seconds = float(metadata.get("planned_interval_s") or 0)
    final = completed_summary(projected,
                              args,
                              repo=repo,
                              out_root=run_dir,
                              monitor_started_at=monitor_started_at,
                              app_commit=str(metadata.get("app_commit") or "missing"),
                              planned_samples=planned_samples,
                              interval_seconds=interval_seconds)
    final["recomputed_at"] = utc_now()
    final["original_monitor_commit"] = str(metadata.get("monitor_commit") or "missing")
    final["source_run_metadata_monitor_started_at"] = metadata.get("monitor_started_at", "missing")
    final["observation_started_at"] = monitor_started_at
    final["observation_started_at_source"] = start_source
    final["observation_finished_at"] = selection_audit["selected_last_captured_at"]
    final["observation_span_s"] = max(
        0.0,
        parsed_utc_timestamp(str(final["observation_finished_at"]))
        - parsed_utc_timestamp(monitor_started_at),
    )
    final["sample_selection"] = selection_audit
    final["source_jsonl"] = str(jsonl_path)
    final["source_jsonl_sha256"] = hashlib.sha256(source_jsonl).hexdigest()
    final["recomputed_jsonl"] = str(recomputed_jsonl_path)
    final["jsonl"] = str(recomputed_jsonl_path)
    # Recomputed attribution is a separate derivative. The append-only source
    # samples and every pulled device artifact remain byte-for-byte untouched;
    # excluded restart records remain named in sample_selection for audit.
    atomic_write_jsonl(recomputed_jsonl_path, projected)
    atomic_write_json(summary_path, final)
    print(f"ATRIA_LONG_WEAR_MONITOR_RECOMPUTED status={final['acceptance_status']} summary={summary_path}")
    return 0


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
    parser.add_argument("--app-commit", help="Installed app source commit to stamp in the evidence summary.")
    parser.add_argument("--recompute-existing-run", type=Path,
                        help="Recompute monitor-owned JSON from existing immutable pull artifacts.")
    parser.add_argument(
        "--launchctl-detach",
        action="store_true",
        help="Submit this monitor run to launchctl and exit after printing the job label.",
    )
    args = parser.parse_args()
    repo = args.repo.resolve()
    if args.recompute_existing_run is not None:
        run_dir = args.recompute_existing_run
        if not run_dir.is_absolute():
            run_dir = (repo / run_dir).resolve()
        return recompute_existing_run(repo, run_dir, args)
    samples_count = int(value_from(args, "samples") or 2)
    interval_seconds = float(value_from(args, "interval") or 300)

    if not args.device:
        print("Set ATRIA_DEVICE_ID or pass --device.", file=sys.stderr)
        return 64
    if samples_count < 1:
        print("--samples must be >= 1", file=sys.stderr)
        return 64
    if args.launchctl_detach:
        label, log_path = submit_detached(repo, args)
        print(f"ATRIA_LONG_WEAR_MONITOR_DETACHED label={label} log={log_path}")
        return 0
    out_root = (repo / args.out_dir / args.label).resolve()
    try:
        prepare_fresh_run_directory(out_root)
    except OSError as error:
        print(f"Refusing to reuse monitor evidence directory: {error}", file=sys.stderr)
        return 73
    jsonl_path = out_root / "samples.jsonl"
    metadata_path = out_root / "run.json"
    summary_path = out_root / "summary.json"
    samples: list[dict[str, object]] = []
    cumulative: dict[str, object] = {}
    monitor_started_at = utc_now()
    write_run_metadata(metadata_path,
                       repo,
                       args,
                       samples_count=samples_count,
                       interval_seconds=interval_seconds,
                       monitor_started_at=monitor_started_at)

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
        item.update(project_run_attributed_evidence(
            pull_dir,
            monitor_started_at,
            stamp,
            float(value_from(args, "max_gap") or 0),
            cumulative=cumulative,
        ))
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

    final = completed_summary(samples,
                              args,
                              repo=repo,
                              out_root=out_root,
                              monitor_started_at=monitor_started_at,
                              app_commit=args.app_commit,
                              planned_samples=samples_count,
                              interval_seconds=interval_seconds)
    atomic_write_json(summary_path, final)
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
