#!/usr/bin/env python3
"""Audit Atria realtime BLE validation evidence against docs/15."""

from __future__ import annotations

import argparse
import json
from datetime import datetime
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path("logs/live-device/realtime-ble-monitor")
MIN_DAYTIME_DURATION_SECONDS = 2 * 60 * 60
MIN_DAYTIME_SAMPLES = 61


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def numeric(value: object) -> float:
    if isinstance(value, bool):
        return float(int(value))
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return 0.0
    return 0.0


def latest_summaries(root: Path) -> list[Path]:
    if not root.exists():
        return []
    return sorted(root.glob("*/summary.json"), key=lambda path: path.stat().st_mtime)


def summary_duration_seconds(summary: dict[str, Any]) -> float:
    start = parse_time(summary.get("started_at"))
    finish = parse_time(summary.get("finished_at"))
    if start and finish:
        return max(0.0, (finish - start).total_seconds())
    samples = numeric(summary.get("samples"))
    interval = numeric(summary.get("planned_interval_s"))
    if samples > 1 and interval > 0:
        return (samples - 1) * interval
    return 0.0


def base_stream_blockers(summary: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    if summary.get("status") != "pass":
        blockers.append("summary_status_not_pass")
    flags = summary.get("flags") or []
    if flags:
        blockers.append("summary_flags_present")
    if numeric(summary.get("min_raw_notification_delta")) <= 0:
        blockers.append("no_positive_raw_delta_on_every_tick")
    if numeric(summary.get("max_disconnect_delta")) != 0:
        blockers.append("disconnect_delta_nonzero")
    if numeric(summary.get("max_hr_continuity_delta")) != 0:
        blockers.append("hr_continuity_delta_nonzero")
    return blockers


def state_fields(summary: dict[str, Any]) -> dict[str, Any]:
    state = summary.get("state_pull")
    if not isinstance(state, dict):
        return {}
    fields = state.get("fields")
    return fields if isinstance(fields, dict) else {}


def daytime_blockers(summary: dict[str, Any]) -> list[str]:
    blockers = base_stream_blockers(summary)
    duration = summary_duration_seconds(summary)
    if duration < MIN_DAYTIME_DURATION_SECONDS:
        blockers.append("daytime_monitor_under_2h")
    if numeric(summary.get("samples")) < MIN_DAYTIME_SAMPLES:
        blockers.append("daytime_monitor_too_few_samples")
    state = summary.get("state_pull")
    if not isinstance(state, dict) or state.get("status") != "ok":
        blockers.append("missing_ok_state_pull")
        return blockers
    fields = state_fields(summary)
    if fields.get("active_journal_freshness") != "fresh":
        blockers.append("active_journal_not_fresh")
    if fields.get("active_journal_continuity_status") != "active":
        blockers.append("active_journal_not_active")
    if numeric(fields.get("active_journal_duration_s")) < MIN_DAYTIME_DURATION_SECONDS:
        blockers.append("active_journal_duration_under_2h")
    if numeric(fields.get("active_journal_samples")) < MIN_DAYTIME_SAMPLES:
        blockers.append("active_journal_too_few_samples")
    if fields.get("file_durability_status") not in {"saved_sessions_present", "saved_sessions_preserved"}:
        blockers.append("file_durability_not_proven")
    return blockers


def has_event(summary: dict[str, Any], label: str) -> bool:
    events = summary.get("events")
    if not isinstance(events, dict):
        return False
    return any(label in labels for labels in events.values() if isinstance(labels, list))


def event_outcome(summary: dict[str, Any], label: str) -> dict[str, Any] | None:
    outcomes = summary.get("event_outcomes")
    if not isinstance(outcomes, list):
        return None
    for outcome in outcomes:
        events = outcome.get("events") if isinstance(outcome, dict) else None
        if isinstance(events, list) and label in events:
            return outcome
    return None


def stress_blockers(summary: dict[str, Any], reseat_label: str, *, allow_small_churn: bool = False) -> list[str]:
    blockers = base_stream_blockers(summary)
    if not has_event(summary, reseat_label):
        blockers.append(f"missing_event_{reseat_label}")
    outcome = event_outcome(summary, reseat_label)
    if outcome is None:
        blockers.append(f"missing_event_outcome_{reseat_label}")
    else:
        if outcome.get("status") != "recovered":
            blockers.append(f"event_not_recovered_{reseat_label}")
        if numeric(outcome.get("next_raw_notification_delta")) <= 0:
            blockers.append(f"event_no_next_raw_delta_{reseat_label}")
        churn_limit = 3 if allow_small_churn else 1
        if numeric(outcome.get("next_disconnect_delta")) >= churn_limit:
            blockers.append(f"event_disconnect_churn_{reseat_label}")
        if numeric(outcome.get("next_hr_continuity_delta")) >= churn_limit:
            blockers.append(f"event_hr_continuity_churn_{reseat_label}")
    return blockers


def best_candidate(paths: list[Path], predicate, blocker_fn) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for path in paths:
        summary = load_json(path)
        if not predicate(summary, path):
            continue
        blockers = blocker_fn(summary)
        candidates.append({
            "summary": str(path),
            "status": "pass" if not blockers else "incomplete",
            "blockers": blockers,
            "samples": summary.get("samples"),
            "duration_s": int(summary_duration_seconds(summary)),
            "min_raw_notification_delta": summary.get("min_raw_notification_delta"),
            "max_disconnect_delta": summary.get("max_disconnect_delta"),
            "max_hr_continuity_delta": summary.get("max_hr_continuity_delta"),
        })
    if not candidates:
        return {"summary": "missing", "status": "missing", "blockers": ["missing_evidence"]}
    candidates.sort(key=lambda item: (item["status"] == "pass", -len(item["blockers"]), item["summary"]))
    return candidates[-1]


def evaluate(root: Path = DEFAULT_ROOT) -> dict[str, Any]:
    paths = latest_summaries(root)
    daytime = best_candidate(
        paths,
        lambda summary, _path: str(summary.get("label", "")).startswith("rt-daytime-")
        or summary_duration_seconds(summary) >= MIN_DAYTIME_DURATION_SECONDS,
        daytime_blockers,
    )
    brief = best_candidate(
        paths,
        lambda summary, _path: has_event(summary, "brief_contact_loss_reseat")
        or "brief-contact-loss" in str(summary.get("label", "")),
        lambda summary: stress_blockers(summary, "brief_contact_loss_reseat"),
    )
    sustained = best_candidate(
        paths,
        lambda summary, _path: has_event(summary, "sustained_silence_reseat")
        or "sustained-silence" in str(summary.get("label", "")),
        lambda summary: stress_blockers(summary, "sustained_silence_reseat", allow_small_churn=True),
    )
    app_switch = best_candidate(
        paths,
        lambda summary, _path: "app-switch" in str(summary.get("label", ""))
        or "clock-switch" in str(summary.get("label", "")),
        base_stream_blockers,
    )
    sections = {
        "daytime_worn_monitor": daytime,
        "brief_contact_loss": brief,
        "sustained_silence_reseat": sustained,
        "app_switch": app_switch,
    }
    blockers = [
        f"{name}:{blocker}"
        for name, section in sections.items()
        if section["status"] != "pass"
        for blocker in section.get("blockers", [])
    ]
    return {
        "status": "pass" if not blockers else "incomplete",
        "root": str(root),
        "requirements": sections,
        "blockers": blockers,
    }


def markdown_summary(report: dict[str, Any]) -> str:
    lines = [
        "# Realtime BLE Validation Audit",
        "",
        f"- Status: `{report['status']}`",
        f"- Evidence root: `{report['root']}`",
        "",
        "## Requirements",
    ]
    for name, section in report["requirements"].items():
        lines.extend([
            f"- `{name}`: `{section['status']}`",
            f"  - Summary: `{section['summary']}`",
            f"  - Blockers: `{', '.join(section.get('blockers', [])) or 'none'}`",
        ])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()

    report = evaluate(args.root)
    if args.markdown:
        print(markdown_summary(report), end="")
    else:
        print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
