#!/usr/bin/env python3
"""Summarize Atria handoff completion evidence from local files."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


LOCAL_CHECK_FILES = [
    Path("test_handoff_static_checks.sh"),
    Path("test_handoff_static_checks.py"),
    Path("test_monitor_long_wear.sh"),
    Path("test_monitor_long_wear.py"),
    Path("tools/monitor_long_wear.py"),
]

REQUIRED_SOURCE_FILES = [
    Path("WhoopApp/WhoopApp/AtriaEntitlements.swift"),
    Path("WhoopApp/WhoopApp/WhoopBLEManager.swift"),
    Path("WhoopApp/WhoopApp/HealthKitExporter.swift"),
    Path("WhoopApp/Info.plist"),
]

ACCESSIBILITY_PERFORMANCE_REQUIRED_CHECKS = [
    "reduce_transparency",
    "increase_contrast",
    "reduce_motion",
    "light_mode",
    "dark_mode",
]
DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY = Path("docs/evidence/accessibility-performance/summary.json")

MIN_SCROLL_FPS = 58.0
MIN_OVERNIGHT_PLANNED_DURATION_S = 10 * 60 * 60
MIN_OVERNIGHT_PLANNED_SAMPLES = 11
MIN_OVERNIGHT_ACCEPTED_SAMPLES = 9
MIN_OVERNIGHT_SPAN_S = 8 * 60 * 60
MIN_OVERNIGHT_COVERAGE_PERCENT = 85.0
MAX_OVERNIGHT_GAP_S = 30.0
MAX_OVERNIGHT_BATTERY_DROP_PERCENT = 35.0
ALLOWED_OVERNIGHT_THERMAL = {"nominal", "fair"}


def load_json(path: Path) -> dict[str, object]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} did not contain a JSON object")
    return data


def latest_summary(repo: Path, explicit: Path | None = None) -> Path | None:
    if explicit:
        candidate = explicit if explicit.is_absolute() else repo / explicit
        return candidate if candidate.exists() else None
    root = repo / "logs/live-device/long-wear-monitor"
    summaries = sorted(root.glob("*/summary.json"), key=lambda path: path.stat().st_mtime)
    return summaries[-1] if summaries else None


def evaluate_physical_long_wear(repo: Path, summary_path: Path | None = None) -> dict[str, object]:
    selected_summary = latest_summary(repo, summary_path)
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

    return {
        "status": "pass" if acceptance_status == "pass" and not audit_blockers else "fail",
        "summary": str(selected_summary),
        "acceptance_status": acceptance_status,
        "acceptance_blockers": blockers,
        "audit_blockers": sorted(set(audit_blockers)),
        "thermal_states": data.get("thermal_states", []),
        "battery_delta": data.get("battery_delta", "missing"),
        "latest_recent_session_span_s": data.get("latest_recent_session_span_s", 0),
        "latest_recent_session_coverage_percent": data.get("latest_recent_session_coverage_percent", 0),
        "preset": data.get("preset", criteria.get("preset", "missing")),
        "planned_samples": data.get("planned_samples", "missing"),
        "planned_duration_s": data.get("planned_duration_s", "missing"),
    }


def accessibility_performance_summary(repo: Path, explicit: Path | None = None) -> Path | None:
    if explicit is None:
        candidate = repo / DEFAULT_ACCESSIBILITY_PERFORMANCE_SUMMARY
        return candidate if candidate.exists() else None
    candidate = explicit if explicit.is_absolute() else repo / explicit
    return candidate if candidate.exists() else None


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
    if not instruments_trace:
        blockers.append("missing_instruments_trace")

    notes = str(data.get("notes", "")).strip()

    return {
        "status": "pass" if not blockers else "fail",
        "summary": str(candidate),
        "blockers": blockers,
        "device": device or "missing",
        "dashboard_scroll_fps": scroll_fps if isinstance(scroll_fps, (int, float)) else "missing",
        "instruments_trace": instruments_trace or "missing",
        "notes": notes,
    }


def evaluate(
    repo: Path,
    summary_path: Path | None = None,
    *,
    skip_external_reference: bool = False,
    accessibility_performance_path: Path | None = None,
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
        "accessibility_performance": accessibility_performance,
        "external_reference_status": "skipped" if skip_external_reference else "required",
        "blockers": sorted(set(blockers)),
    }


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
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    args = parser.parse_args()

    report = evaluate(
        args.repo.resolve(),
        args.summary,
        skip_external_reference=args.skip_external_reference,
        accessibility_performance_path=args.accessibility_performance,
    )
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
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
