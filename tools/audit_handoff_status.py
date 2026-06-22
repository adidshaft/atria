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

MIN_SCROLL_FPS = 58.0


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


def evaluate_accessibility_performance(repo: Path, explicit: Path | None = None) -> dict[str, object]:
    if explicit is None:
        return {
            "status": "missing",
            "summary": "missing",
            "blockers": ["missing_accessibility_performance_summary"],
        }

    candidate = explicit if explicit.is_absolute() else repo / explicit
    if not candidate.exists():
        return {
            "status": "missing",
            "summary": str(candidate),
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

    selected_summary = latest_summary(repo, summary_path)
    physical: dict[str, object]
    if selected_summary is None:
        physical = {
            "status": "missing",
            "summary": "missing",
            "acceptance_status": "missing",
            "acceptance_blockers": ["missing_overnight_summary"],
        }
    else:
        data = load_json(selected_summary)
        blockers = data.get("acceptance_blockers", ["missing_acceptance_blockers"])
        if not isinstance(blockers, list):
            blockers = [str(blockers)]
        acceptance_status = str(data.get("acceptance_status", "missing"))
        physical = {
            "status": "pass" if acceptance_status == "pass" and not blockers else "fail",
            "summary": str(selected_summary),
            "acceptance_status": acceptance_status,
            "acceptance_blockers": blockers,
            "thermal_states": data.get("thermal_states", []),
            "battery_delta": data.get("battery_delta", "missing"),
            "latest_recent_session_span_s": data.get("latest_recent_session_span_s", 0),
            "latest_recent_session_coverage_percent": data.get("latest_recent_session_coverage_percent", 0),
        }

    blockers: list[str] = []
    if local_status != "pass":
        blockers.append("local_artifacts")
    if physical["status"] != "pass":
        blockers.append("physical_long_wear_acceptance")
    blockers.extend(str(item) for item in physical.get("acceptance_blockers", []) if item != "none")
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
