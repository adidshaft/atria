#!/usr/bin/env python3
"""Summarize Atria handoff completion evidence from local files."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


LOCAL_CHECK_FILES = [
    Path("test_handoff_static_checks.sh"),
    Path("test_handoff_static_checks.py"),
    Path("test_monitor_long_wear.sh"),
    Path("test_monitor_long_wear.py"),
    Path("test_prepare_accessibility_performance_evidence.sh"),
    Path("test_prepare_accessibility_performance_evidence.py"),
    Path("tools/capture_accessibility_visual_evidence.sh"),
    Path("tools/capture_dashboard_scroll_performance.sh"),
    Path("tools/monitor_long_wear.py"),
    Path("tools/prepare_accessibility_performance_evidence.py"),
]

REQUIRED_SOURCE_FILES = [
    Path("Atria/Atria/AtriaEntitlements.swift"),
    Path("Atria/Atria/AtriaBLEManager.swift"),
    Path("Atria/Atria/HealthKitExporter.swift"),
    Path("Atria/Info.plist"),
]

ACCESSIBILITY_PERFORMANCE_REQUIRED_CHECKS = [
    "reduce_transparency",
    "increase_contrast",
    "reduce_motion",
    "light_mode",
    "dark_mode",
]
DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY = Path("docs/evidence/accessibility-performance/summary.json")
DEFAULT_DEVICE_PULL_ROOT = Path("tmp/diag")

MIN_SCROLL_FPS = 58.0
MIN_OVERNIGHT_PLANNED_DURATION_S = 10 * 60 * 60
MIN_OVERNIGHT_PLANNED_SAMPLES = 11
MIN_OVERNIGHT_ACCEPTED_SAMPLES = 9
MIN_OVERNIGHT_SPAN_S = 8 * 60 * 60
MIN_OVERNIGHT_COVERAGE_PERCENT = 85.0
MAX_OVERNIGHT_GAP_S = 30.0
MAX_OVERNIGHT_BATTERY_DROP_PERCENT = 35.0
ALLOWED_OVERNIGHT_THERMAL = {"nominal", "fair"}
RUNNING_SAMPLE_OVERDUE_GRACE_S = 10 * 60
PROOF_ONLY_PREFIXES = (
    "docs/evidence/",
    "logs/live-device/",
    "test_",
    "tools/",
)
PROOF_ONLY_FILES = {
    ".gitignore",
}


def load_json(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


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
        return ""
    return result.stdout.strip()


def git_command(repo: Path, args: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            ["git", *args],
            cwd=repo,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None


def commit_is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    if not ancestor or not descendant:
        return False
    if ancestor == descendant:
        return True
    result = git_command(repo, ["merge-base", "--is-ancestor", ancestor, descendant])
    return result is not None and result.returncode == 0


def changed_files_between(repo: Path, older: str, newer: str) -> list[str]:
    if not older or not newer or older == newer:
        return []
    result = git_command(repo, ["diff", "--name-only", f"{older}..{newer}"])
    if result is None or result.returncode != 0:
        return ["<git-diff-unavailable>"]
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def proof_only_changes_since_app_commit(repo: Path, app_commit: str, expected_commit: str) -> bool:
    if app_commit == expected_commit:
        return True
    if not commit_is_ancestor(repo, app_commit, expected_commit):
        return False
    changed = changed_files_between(repo, app_commit, expected_commit)
    return bool(changed) and all(
        path in PROOF_ONLY_FILES or path.startswith(PROOF_ONLY_PREFIXES)
        for path in changed
    )


def is_utc_timestamp(value: str) -> bool:
    if not value.endswith("Z"):
        return False
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError:
        return False
    return parsed.tzinfo == timezone.utc


def parse_utc_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value.removesuffix("Z") + "+00:00")
    except ValueError:
        return None
    return parsed if parsed.tzinfo == timezone.utc else None


def running_long_wear_progress(metadata: dict[str, object],
                               sample_count: int,
                               *,
                               now: datetime | None = None) -> dict[str, object]:
    started = parse_utc_timestamp(metadata.get("monitor_started_at"))
    planned_samples = metadata.get("planned_samples", MIN_OVERNIGHT_PLANNED_SAMPLES)
    planned_duration = metadata.get("planned_duration_s", MIN_OVERNIGHT_PLANNED_DURATION_S)
    interval = metadata.get("planned_interval_s", 0)
    if not isinstance(planned_samples, int):
        planned_samples = MIN_OVERNIGHT_PLANNED_SAMPLES
    if not isinstance(planned_duration, (int, float)):
        planned_duration = MIN_OVERNIGHT_PLANNED_DURATION_S
    if not isinstance(interval, (int, float)) or interval <= 0:
        interval = float(planned_duration) / max(1, int(planned_samples) - 1)

    remaining_samples = max(0, int(planned_samples) - sample_count)
    progress: dict[str, object] = {
        "running_elapsed_s": "pending",
        "running_expected_finish_at": "pending",
        "running_next_sample_overdue_s": 0.0,
        "running_next_sample_due_at": "pending",
        "running_remaining_samples": remaining_samples,
        "running_sample_overdue": False,
    }
    if started is None:
        return progress

    current = now or datetime.now(timezone.utc)
    elapsed = max(0.0, (current - started).total_seconds())
    expected_finish = started.timestamp() + float(planned_duration)
    next_sample_index = min(sample_count, max(0, int(planned_samples) - 1))
    next_sample_due = started.timestamp() + (next_sample_index * float(interval))
    overdue_s = 0.0
    if sample_count < int(planned_samples):
        overdue_s = max(0.0, current.timestamp() - next_sample_due)
    progress.update({
        "running_elapsed_s": elapsed,
        "running_expected_finish_at": datetime.fromtimestamp(expected_finish, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
        "running_next_sample_overdue_s": overdue_s,
        "running_next_sample_due_at": datetime.fromtimestamp(next_sample_due, tz=timezone.utc).isoformat().replace("+00:00", "Z"),
        "running_sample_overdue": overdue_s > RUNNING_SAMPLE_OVERDUE_GRACE_S,
    })
    return progress


def launchctl_long_wear_label(label: object) -> str:
    raw = str(label or "run")
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", raw).strip("-")
    return f"com.adidshaft.atria.longwear.{safe or 'run'}"


def parse_launchctl_service(output: str) -> dict[str, object]:
    state = "missing"
    pid: int | str = "missing"
    runs: int | str = "missing"
    last_exit = "missing"
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if state == "missing":
            match = re.fullmatch(r"state = (.+)", line)
            if match:
                state = match.group(1)
                continue
        if pid == "missing":
            match = re.fullmatch(r"pid = (\d+)", line)
            if match:
                pid = int(match.group(1))
                continue
        if runs == "missing":
            match = re.fullmatch(r"runs = (\d+)", line)
            if match:
                runs = int(match.group(1))
                continue
        if last_exit == "missing":
            match = re.fullmatch(r"last exit code = (.+)", line)
            if match:
                last_exit = match.group(1)
    status = "running" if state == "running" else "not_running"
    return {
        "launchctl_status": status,
        "launchctl_state": state,
        "launchctl_pid": pid,
        "launchctl_runs": runs,
        "launchctl_last_exit": last_exit,
    }


def inspect_launchctl_service(label: str) -> dict[str, object]:
    if not label:
        return {"launchctl_status": "missing_label"}
    try:
        result = subprocess.run(
            ["launchctl", "print", f"gui/{os.getuid()}/{label}"],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except OSError:
        return {"launchctl_status": "unavailable"}
    if result.returncode != 0:
        return {
            "launchctl_status": "not_found",
            "launchctl_state": "missing",
            "launchctl_pid": "missing",
            "launchctl_runs": "missing",
            "launchctl_last_exit": "missing",
        }
    return parse_launchctl_service(result.stdout)


def latest_summary(repo: Path, explicit: Path | None = None) -> Path | None:
    if explicit:
        candidate = explicit if explicit.is_absolute() else repo / explicit
        return candidate if candidate.exists() else None
    root = repo / "logs/live-device/long-wear-monitor"
    summaries = sorted(root.glob("*/summary.json"), key=lambda path: path.stat().st_mtime)
    return summaries[-1] if summaries else None


def latest_running_overnight_samples(repo: Path) -> Path | None:
    root = repo / "logs/live-device/long-wear-monitor"
    candidates: list[Path] = []
    for path in root.glob("*/samples.jsonl"):
        if (path.parent / "summary.json").exists():
            continue
        if "overnight" not in path.parent.name:
            continue
        if path.stat().st_size <= 0:
            continue
        candidates.append(path)
    return sorted(candidates, key=lambda path: path.stat().st_mtime)[-1] if candidates else None


def load_jsonl_last(path: Path) -> dict[str, object]:
    items = load_jsonl_items(path)
    return items[-1] if items else {}


def load_jsonl_items(path: Path) -> list[dict[str, object]]:
    items: list[dict[str, object]] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            items.append(item)
    return items


def sample_numeric_series(samples: list[dict[str, object]], section: str, key: str) -> list[float]:
    values: list[float] = []
    for sample in samples:
        section_data = sample.get(section, {})
        if not isinstance(section_data, dict):
            continue
        value = section_data.get(key)
        if isinstance(value, (int, float)):
            values.append(float(value))
    return values


def sample_nondecreasing(values: list[float]) -> bool | str:
    if len(values) < 2:
        return "pending"
    return all(current >= previous for previous, current in zip(values, values[1:]))


def running_sample_trends(samples: list[dict[str, object]]) -> dict[str, object]:
    active_duration = sample_numeric_series(samples, "active_journal", "duration_s")
    active_hr = sample_numeric_series(samples, "active_journal", "accepted_hr")
    active_rr = sample_numeric_series(samples, "active_journal", "delta_rr")
    batteries = sample_numeric_series(samples, "active_journal", "battery")
    return {
        "active_duration_nondecreasing": sample_nondecreasing(active_duration),
        "active_hr_nondecreasing": sample_nondecreasing(active_hr),
        "active_rr_nondecreasing": sample_nondecreasing(active_rr),
        "battery_drop_from_first_percent": (batteries[-1] - batteries[0]) if batteries else "missing",
    }


def load_running_metadata(samples_path: Path) -> dict[str, object]:
    metadata = samples_path.parent / "run.json"
    if not metadata.exists():
        return {}
    try:
        return load_json(metadata)
    except (OSError, ValueError, json.JSONDecodeError):
        return {}


def evaluate_running_long_wear(samples_path: Path) -> dict[str, object]:
    sample_items = load_jsonl_items(samples_path)
    item = sample_items[-1] if sample_items else {}
    metadata = load_running_metadata(samples_path)
    samples = len(sample_items)
    active = item.get("active_journal", {})
    sessions = item.get("sessions", {})
    if not isinstance(active, dict):
        active = {}
    if not isinstance(sessions, dict):
        sessions = {}
    launchctl_label = launchctl_long_wear_label(metadata.get("label", samples_path.parent.name))
    result = {
        "status": "in_progress",
        "summary": str(samples_path),
        "label": metadata.get("label", samples_path.parent.name),
        "launchctl_label": launchctl_label,
        "acceptance_status": "running",
        "acceptance_blockers": ["overnight_summary_pending"],
        "audit_blockers": ["overnight_summary_pending"],
        "acceptance_diagnostics": {},
        "thermal_states": [active.get("thermal", "missing")] if active.get("thermal") else [],
        "battery_delta": "pending",
        "latest_recent_session_span_s": sessions.get("recent_span_s", 0),
        "latest_recent_session_coverage_percent": sessions.get("recent_coverage_percent", 0),
        "latest_active_status": active.get("status", "missing"),
        "latest_active_duration_s": active.get("duration_s", 0),
        "latest_active_accepted_hr": active.get("accepted_hr", 0),
        "latest_active_delta_rr": active.get("delta_rr", 0),
        "latest_active_segments": active.get("segments", 0),
        "latest_active_battery": active.get("battery", "missing"),
        "latest_active_bpm": active.get("latest_bpm", "missing"),
        **running_sample_trends(sample_items),
        "preset": metadata.get("preset", "overnight"),
        "planned_samples": metadata.get("planned_samples", MIN_OVERNIGHT_PLANNED_SAMPLES),
        "planned_duration_s": metadata.get("planned_duration_s", MIN_OVERNIGHT_PLANNED_DURATION_S),
        "running_samples": samples,
        "latest_sample": item.get("sample", "missing"),
        "latest_sample_at": item.get("captured_at", "missing"),
        "latest_sample_log": item.get("log", "missing"),
        "app_commit": metadata.get("app_commit", "pending"),
        "monitor_commit": metadata.get("monitor_commit", "pending"),
        "expected_app_commit": "pending",
        "monitor_started_at": metadata.get("monitor_started_at", "pending"),
        "monitor_finished_at": "pending",
    }
    launchctl = inspect_launchctl_service(launchctl_label)
    result.update(launchctl)
    if launchctl.get("launchctl_status") == "not_running":
        result["audit_blockers"].append("overnight_monitor_not_running")
    progress = running_long_wear_progress(metadata, samples)
    result.update(progress)
    if progress.get("running_sample_overdue") is True:
        result["audit_blockers"].append("overnight_sample_overdue")
    return result


def evaluate_physical_long_wear(repo: Path, summary_path: Path | None = None) -> dict[str, object]:
    selected_summary = latest_summary(repo, summary_path)
    if summary_path is None:
        running_samples = latest_running_overnight_samples(repo)
        if running_samples is not None and (
            selected_summary is None or running_samples.stat().st_mtime > selected_summary.stat().st_mtime
        ):
            return evaluate_running_long_wear(running_samples)
    if selected_summary is None:
        return {
            "status": "missing",
            "summary": "missing",
            "acceptance_status": "missing",
            "acceptance_blockers": ["missing_overnight_summary"],
            "audit_blockers": ["missing_overnight_summary"],
        }

    data = load_json(selected_summary)
    blockers = data.get("acceptance_blockers", ["missing_acceptance_blockers"])
    if not isinstance(blockers, list):
        blockers = [str(blockers)]
    acceptance_status = str(data.get("acceptance_status", "missing"))
    audit_blockers = [str(item) for item in blockers if item != "none"]

    criteria = data.get("criteria", {})
    if not isinstance(criteria, dict):
        criteria = {}
    if str(data.get("preset", criteria.get("preset", ""))) != "overnight":
        audit_blockers.append("overnight_preset")
    if int(data.get("planned_samples", 0) or 0) < MIN_OVERNIGHT_PLANNED_SAMPLES:
        audit_blockers.append("overnight_planned_samples")
    if float(data.get("planned_duration_s", 0) or 0) < MIN_OVERNIGHT_PLANNED_DURATION_S:
        audit_blockers.append("overnight_planned_duration")
    if int(criteria.get("min_samples", 0) or 0) < MIN_OVERNIGHT_ACCEPTED_SAMPLES:
        audit_blockers.append("overnight_min_samples")
    if float(criteria.get("min_span_s", 0) or 0) < MIN_OVERNIGHT_SPAN_S:
        audit_blockers.append("overnight_min_span")
    if float(criteria.get("min_coverage_percent", 0) or 0) < MIN_OVERNIGHT_COVERAGE_PERCENT:
        audit_blockers.append("overnight_min_coverage")
    if float(criteria.get("max_gap_s", 999_999) or 999_999) > MAX_OVERNIGHT_GAP_S:
        audit_blockers.append("overnight_max_gap")
    if float(criteria.get("max_battery_drop_percent", 999_999) or 999_999) > MAX_OVERNIGHT_BATTERY_DROP_PERCENT:
        audit_blockers.append("overnight_max_battery_drop")
    allowed_thermal = criteria.get("allowed_thermal", [])
    if not isinstance(allowed_thermal, list) or not set(str(item) for item in allowed_thermal).issubset(ALLOWED_OVERNIGHT_THERMAL):
        audit_blockers.append("overnight_allowed_thermal")
    diagnostics = data.get("acceptance_diagnostics", {})
    if not isinstance(diagnostics, dict) or not diagnostics:
        diagnostics = synthesized_long_wear_diagnostics(data, criteria)
    app_commit = str(data.get("app_commit", "")).strip()
    monitor_commit = str(data.get("monitor_commit", "")).strip()
    expected_commit = current_git_commit(repo)
    if not app_commit:
        audit_blockers.append("missing_long_wear_app_commit")
    elif expected_commit and not proof_only_changes_since_app_commit(repo, app_commit, expected_commit):
        audit_blockers.append("long_wear_app_commit_mismatch")
    monitor_started_at = str(data.get("monitor_started_at", "")).strip()
    if not monitor_started_at:
        audit_blockers.append("missing_long_wear_monitor_started_at")
    elif not is_utc_timestamp(monitor_started_at):
        audit_blockers.append("invalid_long_wear_monitor_started_at")
    monitor_finished_at = str(data.get("monitor_finished_at", "")).strip()
    if not monitor_finished_at:
        audit_blockers.append("missing_long_wear_monitor_finished_at")
    elif not is_utc_timestamp(monitor_finished_at):
        audit_blockers.append("invalid_long_wear_monitor_finished_at")

    return {
        "status": "pass" if acceptance_status == "pass" and not audit_blockers else "fail",
        "summary": str(selected_summary),
        "acceptance_status": acceptance_status,
        "acceptance_blockers": blockers,
        "acceptance_diagnostics": diagnostics,
        "audit_blockers": sorted(set(audit_blockers)),
        "thermal_states": data.get("thermal_states", []),
        "battery_delta": data.get("battery_delta", "missing"),
        "latest_recent_session_span_s": data.get("latest_recent_session_span_s", 0),
        "latest_recent_session_coverage_percent": data.get("latest_recent_session_coverage_percent", 0),
        "active_duration_nondecreasing": data.get("active_duration_nondecreasing", "missing"),
        "active_hr_nondecreasing": data.get("active_hr_nondecreasing", "missing"),
        "active_rr_nondecreasing": data.get("active_rr_nondecreasing", "missing"),
        "battery_drop_from_first_percent": data.get("battery_drop_from_first_percent", data.get("battery_delta", "missing")),
        "preset": data.get("preset", criteria.get("preset", "missing")),
        "planned_samples": data.get("planned_samples", "missing"),
        "planned_duration_s": data.get("planned_duration_s", "missing"),
        "app_commit": app_commit or "missing",
        "monitor_commit": monitor_commit or "missing",
        "expected_app_commit": expected_commit or "missing",
        "monitor_started_at": monitor_started_at or "missing",
        "monitor_finished_at": monitor_finished_at or "missing",
    }


def synthesized_long_wear_diagnostics(data: dict[str, object], criteria: dict[str, object]) -> dict[str, object]:
    min_samples = int(criteria.get("min_samples", 0) or 0)
    min_span = float(criteria.get("min_span_s", 0) or 0)
    min_coverage = float(criteria.get("min_coverage_percent", 0) or 0)
    max_gap = float(criteria.get("max_gap_s", 0) or 0)
    max_battery_drop = float(criteria.get("max_battery_drop_percent", 0) or 0)
    allowed_thermal = criteria.get("allowed_thermal", [])
    if not isinstance(allowed_thermal, list):
        allowed_thermal = []
    thermal_states = data.get("thermal_states", [])
    if not isinstance(thermal_states, list):
        thermal_states = []
    battery_delta = data.get("battery_delta", "missing")
    battery_ok = isinstance(battery_delta, (int, float)) and battery_delta >= -max_battery_drop
    samples = int(data.get("samples", 0) or 0)
    active_ok_samples = int(data.get("active_ok_samples", 0) or 0)
    session_span = float(data.get("latest_recent_session_span_s", 0) or 0)
    session_coverage = float(data.get("latest_recent_session_coverage_percent", 0) or 0)
    active_gap = float(data.get("max_active_accepted_gap_s", 0) or 0)
    recent_gap = float(data.get("max_recent_accepted_gap_s", 0) or 0)

    return {
        "samples": {"observed": samples, "required_min": min_samples, "ok": samples >= min_samples},
        "active_ok_samples": {
            "observed": active_ok_samples,
            "required_min": min_samples,
            "ok": active_ok_samples >= min_samples,
        },
        "session_span": {
            "observed_s": session_span,
            "required_min_s": min_span,
            "ok": session_span >= min_span,
        },
        "session_coverage": {
            "observed_percent": session_coverage,
            "required_min_percent": min_coverage,
            "ok": session_coverage >= min_coverage,
        },
        "active_gap": {"observed_s": active_gap, "required_max_s": max_gap, "ok": active_gap <= max_gap},
        "recent_gap": {"observed_s": recent_gap, "required_max_s": max_gap, "ok": recent_gap <= max_gap},
        "thermal": {
            "observed": sorted(str(item) for item in thermal_states),
            "allowed": [str(item) for item in allowed_thermal],
            "ok": bool(thermal_states) and set(str(item) for item in thermal_states).issubset(str(item) for item in allowed_thermal),
        },
        "battery": {
            "observed_delta_percent": battery_delta,
            "required_min_delta_percent": -max_battery_drop,
            "ok": battery_ok,
        },
    }


def accessibility_performance_summary(repo: Path, explicit: Path | None = None) -> Path | None:
    if explicit is None:
        candidate = repo / DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY
        return candidate if candidate.exists() else None
    candidate = explicit if explicit.is_absolute() else repo / explicit
    return candidate if candidate.exists() else None


def trace_toc_sidecar(path: Path) -> Path:
    return path.with_name(path.name + ".toc.xml")


def parse_xctrace_toc(xml_text: str) -> dict[str, object]:
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return {"status": "invalid_xml"}
    device = root.find(".//target/device")
    process = root.find(".//target/process")
    template_name = root.findtext(".//summary/template-name", default="")
    duration_text = root.findtext(".//summary/duration", default="")
    try:
        duration = float(duration_text)
    except ValueError:
        duration = 0.0
    return {
        "status": "ok",
        "device_model": device.attrib.get("model", "") if device is not None else "",
        "process_name": process.attrib.get("name", "") if process is not None else "",
        "template_name": template_name,
        "duration_s": duration,
    }


def export_xctrace_toc(path: Path) -> str:
    sidecar = trace_toc_sidecar(path)
    if sidecar.exists():
        return sidecar.read_text(encoding="utf-8", errors="replace")
    result = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", str(path), "--toc"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.stdout if result.returncode == 0 else ""


def evaluate_instruments_trace(path: Path) -> dict[str, object]:
    metadata = parse_xctrace_toc(export_xctrace_toc(path))
    blockers: list[str] = []
    if metadata.get("status") != "ok":
        blockers.append("invalid_instruments_trace_toc")
    if metadata.get("device_model") not in {"iPhone 15 Pro", ""}:
        blockers.append("instruments_trace_device")
    if metadata.get("process_name") not in {"Atria", ""}:
        blockers.append("instruments_trace_process")
    if metadata.get("template_name") not in {"Time Profiler", ""}:
        blockers.append("instruments_trace_template")
    duration = metadata.get("duration_s")
    if isinstance(duration, (int, float)) and duration <= 0:
        blockers.append("instruments_trace_duration")
    return {"metadata": metadata, "blockers": blockers}


def latest_device_pull_summary(repo: Path, explicit: Path | None = None) -> Path | None:
    if explicit is not None:
        candidate = explicit if explicit.is_absolute() else repo / explicit
        return candidate if candidate.exists() else None
    root = repo / DEFAULT_DEVICE_PULL_ROOT
    summaries = sorted(root.glob("*/pull-summary.txt"), key=lambda path: path.stat().st_mtime)
    return summaries[-1] if summaries else None


def parse_key_value_summary(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or " " in key:
            continue
        values[key] = value.strip()
    return values


def evaluate_latest_device_pull(repo: Path, explicit: Path | None = None) -> dict[str, object]:
    candidate = latest_device_pull_summary(repo, explicit)
    if candidate is None:
        return {
            "status": "missing",
            "summary": str(repo / DEFAULT_DEVICE_PULL_ROOT / "*/pull-summary.txt") if explicit is None else str(explicit),
        }

    values = parse_key_value_summary(candidate)
    process_running = values.get("process_status") == "running"
    journal_ok = values.get("active_journal_final_status") == "ok"
    continuity = values.get("active_journal_continuity_status", "missing")
    official_whoop_risk = values.get("official_whoop_coexistence_risk", "missing")
    battery_usable = values.get("battery_usable", "missing")
    rr_status = values.get("active_journal_rr_status", "missing")
    rr_local_ready = values.get("active_journal_rr_gate_b_local_ready", "missing")
    rr_healthy = rr_status != "rr_present" or rr_local_ready in {"1", "missing"}

    healthy = (
        process_running
        and journal_ok
        and continuity == "active"
        and official_whoop_risk == "0"
        and battery_usable in {"1", "missing"}
        and rr_healthy
    )

    return {
        "status": "ok" if healthy else "attention",
        "summary": str(candidate),
        "process_status": values.get("process_status", "missing"),
        "official_whoop_coexistence_risk": official_whoop_risk,
        "active_journal_final_status": values.get("active_journal_final_status", "missing"),
        "active_journal_continuity_status": continuity,
        "active_journal_rr_status": rr_status,
        "active_journal_rr_gate_b_local_ready": rr_local_ready,
        "active_journal_rr_raw_beats": values.get("active_journal_rr_raw_beats", "missing"),
        "active_journal_rr_corrected_beats": values.get("active_journal_rr_corrected_beats", "missing"),
        "active_journal_rr_kept_percent": values.get("active_journal_rr_kept_percent", "missing"),
        "active_journal_rr_max_gap_s": values.get("active_journal_rr_max_gap_s", "missing"),
        "active_journal_rr_gate_b_local_blocker": values.get("active_journal_rr_gate_b_local_blocker", "missing"),
        "battery_level": values.get("battery_level", "missing"),
        "battery_charge_status": values.get("battery_charge_status", "missing"),
        "battery_is_charging": values.get("battery_is_charging", "missing"),
        "battery_usable": battery_usable,
    }


def evaluate_accessibility_performance(repo: Path, explicit: Path | None = None) -> dict[str, object]:
    candidate = accessibility_performance_summary(repo, explicit)
    if candidate is None:
        return {
            "status": "missing",
            "summary": str(repo / DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY) if explicit is None else str(explicit),
            "blockers": ["missing_accessibility_performance_summary"],
        }

    data = load_json(candidate)
    blockers: list[str] = []
    device = str(data.get("device", "")).strip()
    if device != "iPhone 15 Pro":
        blockers.append("accessibility_performance_device")

    checks = data.get("accessibility_checks", {})
    if not isinstance(checks, dict):
        checks = {}
    missing_checks = [
        check for check in ACCESSIBILITY_PERFORMANCE_REQUIRED_CHECKS
        if checks.get(check) is not True
    ]
    blockers.extend(f"accessibility_{check}" for check in missing_checks)

    scroll_fps = data.get("dashboard_scroll_fps")
    if not isinstance(scroll_fps, (int, float)) or float(scroll_fps) < MIN_SCROLL_FPS:
        blockers.append("dashboard_scroll_fps")

    instruments_trace = str(data.get("instruments_trace", "")).strip()
    resolved_trace: Path | None = None
    trace_metadata: dict[str, object] = {}
    if not instruments_trace:
        blockers.append("missing_instruments_trace")
    else:
        trace_path = Path(instruments_trace)
        resolved_trace = trace_path if trace_path.is_absolute() else repo / trace_path
        if not resolved_trace.exists():
            blockers.append("missing_instruments_trace_file")
        else:
            trace_evaluation = evaluate_instruments_trace(resolved_trace)
            trace_metadata = trace_evaluation["metadata"]
            blockers.extend(str(item) for item in trace_evaluation["blockers"])

    measured_at = str(data.get("measured_at", "")).strip()
    if not measured_at:
        blockers.append("missing_measured_at")
    elif not is_utc_timestamp(measured_at):
        blockers.append("invalid_measured_at")

    app_commit = str(data.get("app_commit", "")).strip()
    if not app_commit:
        blockers.append("missing_app_commit")
    expected_commit = current_git_commit(repo)
    if app_commit and expected_commit and not proof_only_changes_since_app_commit(repo, app_commit, expected_commit):
        blockers.append("app_commit_mismatch")

    app_build = str(data.get("app_build", "")).strip()
    if not app_build:
        blockers.append("missing_app_build")

    notes = str(data.get("notes", "")).strip()

    return {
        "status": "pass" if not blockers else "fail",
        "summary": str(candidate),
        "blockers": blockers,
        "device": device or "missing",
        "dashboard_scroll_fps": scroll_fps if isinstance(scroll_fps, (int, float)) else "missing",
        "instruments_trace": instruments_trace or "missing",
        "instruments_trace_exists": resolved_trace.exists() if resolved_trace else False,
        "instruments_trace_metadata": trace_metadata,
        "measured_at": measured_at or "missing",
        "app_commit": app_commit or "missing",
        "expected_app_commit": expected_commit or "missing",
        "app_build": app_build or "missing",
        "notes": notes,
    }


def evaluate(
    repo: Path,
    summary_path: Path | None = None,
    *,
    skip_external_reference: bool = False,
    accessibility_performance_path: Path | None = None,
    device_pull_path: Path | None = None,
) -> dict[str, object]:
    missing_local = [str(path) for path in LOCAL_CHECK_FILES if not (repo / path).exists()]
    missing_source = [str(path) for path in REQUIRED_SOURCE_FILES if not (repo / path).exists()]
    local_status = "pass" if not missing_local and not missing_source else "fail"

    physical = evaluate_physical_long_wear(repo, summary_path)

    blockers: list[str] = []
    if local_status != "pass":
        blockers.append("local_artifacts")
    if physical["status"] != "pass":
        blockers.append("physical_long_wear_acceptance")
    blockers.extend(str(item) for item in physical.get("audit_blockers", []))
    accessibility_performance = evaluate_accessibility_performance(repo, accessibility_performance_path)
    latest_device_pull = evaluate_latest_device_pull(repo, device_pull_path)
    if accessibility_performance["status"] != "pass":
        blockers.append("accessibility_performance_proof")
    blockers.extend(str(item) for item in accessibility_performance.get("blockers", []))
    if not skip_external_reference:
        blockers.append("external_reference_validation")

    return {
        "status": "complete" if not blockers else "not_complete",
        "local_status": local_status,
        "missing_local_files": missing_local,
        "missing_source_files": missing_source,
        "physical_long_wear": physical,
        "latest_device_pull": latest_device_pull,
        "accessibility_performance": accessibility_performance,
        "external_reference_status": "skipped" if skip_external_reference else "required",
        "blockers": sorted(set(blockers)),
    }


def format_diagnostic_value(value: object) -> str:
    if isinstance(value, float):
        return f"{value:.1f}".rstrip("0").rstrip(".")
    if isinstance(value, list):
        return ", ".join(str(item) for item in value) or "none"
    return str(value)


def next_evidence_items(report: dict[str, object]) -> list[str]:
    blockers = report.get("blockers", [])
    if not isinstance(blockers, list):
        blockers = [str(blockers)]
    blocker_set = {str(item) for item in blockers}
    items: list[str] = []
    if {"overnight_summary_pending", "physical_long_wear_acceptance"} & blocker_set:
        physical = report.get("physical_long_wear", {})
        if isinstance(physical, dict):
            items.append(
                "Wait for the overnight long-wear monitor to write `summary.json`, then require "
                "`acceptance_status=pass`, at least 9 successful samples, at least 8h persisted-session span, "
                "at least 85% coverage, accepted-gap <= 30s, nominal/fair thermal, and battery drop within limit."
            )
    if "dashboard_scroll_fps" in blocker_set:
        items.append(
            "Measure real dashboard scroll FPS on the physical iPhone 15 Pro Release app. "
            "Use `tools/capture_dashboard_scroll_performance.sh --device <device> --app-commit <installed-app-commit>` "
            "to capture a timed scroll trace/video, then rerun it with `--measured-fps <fps> --final` "
            "after reading the measured FPS; final mode requires fps >= 58."
        )
    if "external_reference_validation" in blocker_set:
        items.append("Provide the deferred independent external reference validation, or continue auditing with `--skip-external-reference`.")
    if "accessibility_performance_proof" in blocker_set and "dashboard_scroll_fps" not in blocker_set:
        items.append("Inspect the Accessibility / Performance blockers below and regenerate `summary.json` only from measured device evidence.")
    return items


def markdown_summary(report: dict[str, object]) -> str:
    physical = report["physical_long_wear"]
    latest_device_pull = report["latest_device_pull"]
    accessibility = report["accessibility_performance"]
    if not isinstance(physical, dict) or not isinstance(latest_device_pull, dict) or not isinstance(accessibility, dict):
        raise ValueError("audit report did not contain expected sections")

    blockers = report.get("blockers", [])
    if not isinstance(blockers, list):
        blockers = [str(blockers)]

    lines = [
        "# Atria Handoff Status",
        "",
        f"- Status: `{report['status']}`",
        f"- Local checks: `{report['local_status']}`",
        f"- Physical long-wear: `{physical['status']}` (`{physical['acceptance_status']}`)",
        f"- Latest device pull: `{latest_device_pull['status']}`",
        f"- Accessibility/performance: `{accessibility['status']}`",
        f"- External reference: `{report['external_reference_status']}`",
        "",
        "## Blockers",
    ]
    if blockers:
        lines.extend(f"- `{item}`" for item in blockers)
    else:
        lines.append("- none")

    evidence_items = next_evidence_items(report)
    if evidence_items:
        lines.extend(["", "## Next Required Evidence"])
        lines.extend(f"- {item}" for item in evidence_items)

    lines.extend([
        "",
        "## Physical Long-Wear",
        f"- Summary: `{physical['summary']}`",
        f"- Label: `{physical.get('label', 'missing')}`",
        f"- Launchctl label: `{physical.get('launchctl_label', 'missing')}`",
        f"- Launchctl status: `{physical.get('launchctl_status', 'missing')}`",
        f"- Launchctl state: `{physical.get('launchctl_state', 'missing')}`",
        f"- Launchctl PID: `{physical.get('launchctl_pid', 'missing')}`",
        f"- Launchctl last exit: `{physical.get('launchctl_last_exit', 'missing')}`",
        f"- Preset: `{physical.get('preset', 'missing')}`",
        f"- Planned samples: `{physical.get('planned_samples', 'missing')}`",
        f"- Planned duration seconds: `{physical.get('planned_duration_s', 'missing')}`",
        f"- Session span seconds: `{format_diagnostic_value(physical.get('latest_recent_session_span_s', 'missing'))}`",
        f"- Session coverage percent: `{format_diagnostic_value(physical.get('latest_recent_session_coverage_percent', 'missing'))}`",
        f"- Thermal states: `{format_diagnostic_value(physical.get('thermal_states', []))}`",
        f"- Active duration nondecreasing: `{physical.get('active_duration_nondecreasing', 'missing')}`",
        f"- Active HR nondecreasing: `{physical.get('active_hr_nondecreasing', 'missing')}`",
        f"- Active RR nondecreasing: `{physical.get('active_rr_nondecreasing', 'missing')}`",
        f"- Battery drop from first percent: `{format_diagnostic_value(physical.get('battery_drop_from_first_percent', 'missing'))}`",
        f"- App commit: `{physical.get('app_commit', 'missing')}`",
        f"- Monitor started: `{physical.get('monitor_started_at', 'missing')}`",
        f"- Monitor finished: `{physical.get('monitor_finished_at', 'missing')}`",
    ])
    if physical.get("status") == "in_progress":
        lines.extend([
            f"- Running samples: `{physical.get('running_samples', 'missing')}`",
            f"- Running elapsed seconds: `{format_diagnostic_value(physical.get('running_elapsed_s', 'missing'))}`",
            f"- Remaining samples: `{physical.get('running_remaining_samples', 'missing')}`",
            f"- Next sample due: `{physical.get('running_next_sample_due_at', 'missing')}`",
            f"- Next sample overdue: `{physical.get('running_sample_overdue', 'missing')}` "
            f"({format_diagnostic_value(physical.get('running_next_sample_overdue_s', 'missing'))}s)",
            f"- Expected finish: `{physical.get('running_expected_finish_at', 'missing')}`",
            f"- Latest sample: `{physical.get('latest_sample', 'missing')}` at `{physical.get('latest_sample_at', 'missing')}`",
            f"- Latest active journal: `{physical.get('latest_active_status', 'missing')}`, "
            f"duration `{format_diagnostic_value(physical.get('latest_active_duration_s', 'missing'))}s`, "
            f"HR `{physical.get('latest_active_accepted_hr', 'missing')}`, "
            f"RR `{physical.get('latest_active_delta_rr', 'missing')}`, "
            f"segments `{physical.get('latest_active_segments', 'missing')}`, "
            f"battery `{physical.get('latest_active_battery', 'missing')}`, "
            f"BPM `{physical.get('latest_active_bpm', 'missing')}`",
            f"- Latest sample log: `{physical.get('latest_sample_log', 'missing')}`",
        ])

    diagnostics = physical.get("acceptance_diagnostics", {})
    if isinstance(diagnostics, dict) and diagnostics:
        lines.extend(["", "### Long-Wear Diagnostics"])
        for name in sorted(diagnostics):
            diagnostic = diagnostics[name]
            if not isinstance(diagnostic, dict):
                continue
            observed_parts = [
                f"{key}={format_diagnostic_value(value)}"
                for key, value in diagnostic.items()
                if key.startswith("observed")
            ]
            required_parts = [
                f"{key}={format_diagnostic_value(value)}"
                for key, value in diagnostic.items()
                if key.startswith("required") or key == "allowed"
            ]
            ok = diagnostic.get("ok", "missing")
            detail = ", ".join(observed_parts + required_parts + [f"ok={ok}"])
            lines.append(f"- `{name}`: {detail}")

    lines.extend([
        "",
        "## Latest Device Pull",
        f"- Summary: `{latest_device_pull['summary']}`",
        f"- Process: `{latest_device_pull.get('process_status', 'missing')}`",
        f"- Official WHOOP coexistence risk: `{latest_device_pull.get('official_whoop_coexistence_risk', 'missing')}`",
        f"- Active journal: `{latest_device_pull.get('active_journal_final_status', 'missing')}` / `{latest_device_pull.get('active_journal_continuity_status', 'missing')}`",
        f"- Active RR: `{latest_device_pull.get('active_journal_rr_status', 'missing')}`",
        f"- Local RR ready: `{latest_device_pull.get('active_journal_rr_gate_b_local_ready', 'missing')}`",
        f"- RR beats: raw `{latest_device_pull.get('active_journal_rr_raw_beats', 'missing')}`, corrected `{latest_device_pull.get('active_journal_rr_corrected_beats', 'missing')}`, kept `{latest_device_pull.get('active_journal_rr_kept_percent', 'missing')}%`, max gap `{latest_device_pull.get('active_journal_rr_max_gap_s', 'missing')}s`",
        f"- RR blocker: `{latest_device_pull.get('active_journal_rr_gate_b_local_blocker', 'missing')}`",
        f"- Strap battery: `{latest_device_pull.get('battery_level', 'missing')}%`, charge `{latest_device_pull.get('battery_charge_status', 'missing')}`, charging `{latest_device_pull.get('battery_is_charging', 'missing')}`, usable `{latest_device_pull.get('battery_usable', 'missing')}`",
    ])

    lines.extend([
        "",
        "## Accessibility / Performance",
        f"- Summary: `{accessibility['summary']}`",
        f"- Device: `{accessibility.get('device', 'missing')}`",
        f"- Dashboard scroll fps: `{accessibility.get('dashboard_scroll_fps', 'missing')}`",
        f"- Instruments trace: `{accessibility.get('instruments_trace', 'missing')}`",
        f"- Trace exists: `{accessibility.get('instruments_trace_exists', False)}`",
        f"- Measured at: `{accessibility.get('measured_at', 'missing')}`",
        f"- App commit: `{accessibility.get('app_commit', 'missing')}`",
        f"- App build: `{accessibility.get('app_build', 'missing')}`",
    ])
    trace_metadata = accessibility.get("instruments_trace_metadata", {})
    if isinstance(trace_metadata, dict) and trace_metadata:
        lines.append(
            "- Trace metadata: "
            f"`device={trace_metadata.get('device_model', 'missing')}; "
            f"process={trace_metadata.get('process_name', 'missing')}; "
            f"template={trace_metadata.get('template_name', 'missing')}; "
            f"duration_s={format_diagnostic_value(trace_metadata.get('duration_s', 'missing'))}`"
        )
    accessibility_blockers = accessibility.get("blockers", [])
    if isinstance(accessibility_blockers, list) and accessibility_blockers:
        lines.extend(["", "### Accessibility Blockers"])
        lines.extend(f"- `{item}`" for item in accessibility_blockers)

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Atria repo root.")
    parser.add_argument("--summary", type=Path, default=None, help="Specific long-wear monitor summary JSON.")
    parser.add_argument(
        "--accessibility-performance",
        type=Path,
        default=None,
        help="Specific accessibility/performance evidence JSON.",
    )
    parser.add_argument(
        "--skip-external-reference",
        action="store_true",
        help="Treat external reference validation as deliberately deferred/gated for this audit.",
    )
    parser.add_argument(
        "--pull-summary",
        type=Path,
        default=None,
        help="Specific non-disruptive device pull summary to show as current physical state.",
    )
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument("--markdown", action="store_true", help="Print a Markdown handoff status summary.")
    args = parser.parse_args()

    report = evaluate(
        args.repo.resolve(),
        args.summary,
        skip_external_reference=args.skip_external_reference,
        accessibility_performance_path=args.accessibility_performance,
        device_pull_path=args.pull_summary,
    )
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    elif args.markdown:
        print(markdown_summary(report))
    else:
        physical = report["physical_long_wear"]
        print(
            "ATRIA_HANDOFF_AUDIT "
            f"status={report['status']} "
            f"local_status={report['local_status']} "
            f"physical_status={physical['status']} "
            f"acceptance_status={physical['acceptance_status']} "
            f"acceptance_blockers={','.join(physical['acceptance_blockers']) or 'none'} "
            f"accessibility_performance_status={report['accessibility_performance']['status']} "
            f"external_reference_status={report['external_reference_status']} "
            f"blockers={','.join(report['blockers']) or 'none'} "
            f"summary={physical['summary']}"
        )
    return 0 if report["status"] == "complete" else 1


if __name__ == "__main__":
    raise SystemExit(main())
