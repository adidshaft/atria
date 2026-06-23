#!/usr/bin/env python3
"""Audit Atria realtime BLE validation evidence against docs/15."""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path("logs/live-device/realtime-ble-monitor")
MIN_DAYTIME_DURATION_SECONDS = 2 * 60 * 60
MIN_DAYTIME_SAMPLES = 61
MIN_APP_SWITCH_LIFECYCLE_COMMIT = "2a0491d"
EXPECTED_OPERATOR_ACTIONS = {
    "brief_contact_loss_start": "Loosen or lift the strap for about 30 seconds.",
    "brief_contact_loss_reseat": "Reseat the strap firmly now.",
    "sustained_silence_start": "Take the strap off and set it down until the reseat marker.",
    "sustained_silence_reseat": "Reseat the strap firmly now.",
}

NEXT_ACTIONS = {
    "daytime_worn_monitor": {
        "command": (
            "ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B "
            "python3 tools/monitor_realtime_ble.py --samples 91 --interval 120 "
            "--label rt-daytime-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot"
        ),
        "operator_action": "Wear the strap continuously for the full 2+ hour monitor window.",
    },
    "brief_contact_loss": {
        "command": (
            "ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B "
            "python3 tools/monitor_realtime_ble.py --samples 5 --interval 120 "
            "--label rt-brief-contact-loss-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot "
            "--event 1:brief_contact_loss_start --event 2:brief_contact_loss_reseat"
        ),
        "operator_action": "After sample index=1, loosen/lift the strap for about 30 seconds, then reseat before sample index=2.",
    },
    "sustained_silence_reseat": {
        "command": (
            "ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B "
            "python3 tools/monitor_realtime_ble.py --samples 7 --interval 120 "
            "--label rt-sustained-silence-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot "
            "--event 1:sustained_silence_start --event 3:sustained_silence_reseat"
        ),
        "operator_action": "After sample index=1, take the strap off for at least 2.5 minutes, then reseat after sample index=3.",
    },
    "app_switch": {
        "command": (
            "ATRIA_DEVICE_ID=3803F5B6-1666-56D3-A71A-62F131F6CE3B "
            "python3 tools/monitor_realtime_ble.py --samples 4 --interval 120 "
            "--label rt-app-switch-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot"
        ),
        "operator_action": "Foreground another app for about 2 minutes during the monitor, then return to Atria.",
    },
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


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


def load_summary_records(paths: list[Path]) -> tuple[list[tuple[Path, dict[str, Any]]], list[dict[str, str]]]:
    records: list[tuple[Path, dict[str, Any]]] = []
    invalid: list[dict[str, str]] = []
    for path in paths:
        try:
            records.append((path, load_json(path)))
        except (OSError, json.JSONDecodeError) as exc:
            invalid.append({
                "summary": str(path),
                "error": exc.__class__.__name__,
            })
    return records, invalid


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


def commit_includes(commit: object, ancestor: str) -> bool:
    if not isinstance(commit, str) or not commit or commit == "unknown":
        return False
    if commit.startswith(ancestor) or ancestor.startswith(commit):
        return True
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, commit],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def base_stream_blockers(summary: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    if summary.get("worn_expected") is False:
        blockers.append("monitor_ran_not_worn")
    if summary.get("status") != "pass":
        blockers.append("summary_status_not_pass")
    flags = summary.get("flags") or []
    if flags:
        blockers.append("summary_flags_present")
    if numeric(summary.get("min_raw_notification_delta")) <= 0:
        blockers.append("no_positive_raw_delta_on_every_tick")
    if "min_accepted_sample_delta" in summary and numeric(summary.get("min_accepted_sample_delta")) <= 0:
        blockers.append("no_positive_accepted_delta_on_every_tick")
    if numeric(summary.get("max_disconnect_delta")) != 0:
        blockers.append("disconnect_delta_nonzero")
    if numeric(summary.get("max_hr_continuity_delta")) != 0:
        blockers.append("hr_continuity_delta_nonzero")
    return blockers


def app_switch_blockers(summary: dict[str, Any]) -> list[str]:
    blockers = base_stream_blockers(summary)
    blockers.extend(audit_snapshot_blockers(summary))
    blockers.extend(state_pull_blockers(summary))
    if not commit_includes(summary.get("git_commit"), MIN_APP_SWITCH_LIFECYCLE_COMMIT):
        blockers.append("app_switch_evidence_before_disconnect_continuity_fix")
    return blockers


def state_fields(summary: dict[str, Any]) -> dict[str, Any]:
    state = summary.get("state_pull")
    if not isinstance(state, dict):
        return {}
    fields = state.get("fields")
    return fields if isinstance(fields, dict) else {}


def state_pull_blockers(summary: dict[str, Any]) -> list[str]:
    state = summary.get("state_pull")
    if not isinstance(state, dict) or state.get("status") != "ok":
        return ["missing_ok_state_pull"]
    fields = state_fields(summary)
    if fields.get("file_durability_status") not in {"saved_sessions_present", "saved_sessions_preserved"}:
        return ["file_durability_not_proven"]
    return []


def audit_snapshot_blockers(summary: dict[str, Any]) -> list[str]:
    snapshot = summary.get("audit_snapshot")
    if not isinstance(snapshot, dict):
        return ["missing_audit_snapshot"]
    if snapshot.get("status") not in {"pass", "incomplete"}:
        return ["audit_snapshot_status_missing"]
    snapshot_path = snapshot.get("path")
    if not snapshot_path:
        return ["audit_snapshot_path_missing"]
    if not Path(str(snapshot_path)).exists():
        return ["audit_snapshot_file_missing"]
    if numeric(snapshot.get("summary_count")) <= 0:
        return ["audit_snapshot_summary_count_missing"]
    return []


def daytime_blockers(summary: dict[str, Any]) -> list[str]:
    blockers = base_stream_blockers(summary)
    blockers.extend(audit_snapshot_blockers(summary))
    duration = summary_duration_seconds(summary)
    if duration < MIN_DAYTIME_DURATION_SECONDS:
        blockers.append("daytime_monitor_under_2h")
    if numeric(summary.get("samples")) < MIN_DAYTIME_SAMPLES:
        blockers.append("daytime_monitor_too_few_samples")
    state_blockers = state_pull_blockers(summary)
    if state_blockers:
        blockers.extend(state_blockers)
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


def event_sample_index(summary: dict[str, Any], label: str) -> int | None:
    events = summary.get("events")
    if not isinstance(events, dict):
        return None
    found: list[int] = []
    for sample, labels in events.items():
        if isinstance(labels, list) and label in labels:
            try:
                found.append(int(sample))
            except (TypeError, ValueError):
                continue
    return min(found) if found else None


def event_outcome(summary: dict[str, Any], label: str) -> dict[str, Any] | None:
    outcomes = summary.get("event_outcomes")
    if not isinstance(outcomes, list):
        return None
    for outcome in outcomes:
        events = outcome.get("events") if isinstance(outcome, dict) else None
        if isinstance(events, list) and label in events:
            return outcome
    return None


def has_operator_action(summary: dict[str, Any], label: str, sample_index: int | None = None) -> bool:
    expected = EXPECTED_OPERATOR_ACTIONS.get(label)
    actions = summary.get("operator_actions")
    if not isinstance(actions, list):
        return False
    for action in actions:
        if not isinstance(action, dict):
            continue
        if sample_index is not None and numeric(action.get("sample")) != sample_index:
            continue
        events = action.get("events")
        prompts = action.get("actions")
        if not (isinstance(events, list) and label in events and isinstance(prompts, list) and prompts):
            continue
        if expected is not None and expected not in prompts:
            continue
        return True
    return False


def stress_blockers(
    summary: dict[str, Any],
    reseat_label: str,
    *,
    start_label: str | None = None,
    min_start_to_reseat_samples: int = 1,
    min_start_to_reseat_seconds: float = 0,
    require_clean_stream: bool = True,
    allow_small_churn: bool = False,
) -> list[str]:
    blockers = base_stream_blockers(summary) if require_clean_stream else []
    blockers.extend(audit_snapshot_blockers(summary))
    blockers.extend(state_pull_blockers(summary))
    if not require_clean_stream:
        allowed_flags = {"NO_NEW_DATA", "ZERO_CONTACT"}
        flags = set(summary.get("flags") or [])
        unexpected_flags = sorted(flags - allowed_flags)
        if unexpected_flags:
            blockers.append("unexpected_flags_" + "_".join(unexpected_flags))
        if numeric(summary.get("max_disconnect_delta")) >= 3:
            blockers.append("disconnect_churn")
        if numeric(summary.get("max_hr_continuity_delta")) >= 3:
            blockers.append("hr_continuity_churn")
    if start_label and not has_event(summary, start_label):
        blockers.append(f"missing_event_{start_label}")
    if not has_event(summary, reseat_label):
        blockers.append(f"missing_event_{reseat_label}")
    if start_label and not has_operator_action(summary, start_label):
        blockers.append(f"missing_operator_action_{start_label}")
    if not has_operator_action(summary, reseat_label):
        blockers.append(f"missing_operator_action_{reseat_label}")
    if start_label:
        start_index = event_sample_index(summary, start_label)
        reseat_index = event_sample_index(summary, reseat_label)
        if start_index is not None and not has_operator_action(summary, start_label, start_index):
            blockers.append(f"operator_action_sample_mismatch_{start_label}")
        if reseat_index is not None and not has_operator_action(summary, reseat_label, reseat_index):
            blockers.append(f"operator_action_sample_mismatch_{reseat_label}")
        if start_index is not None and reseat_index is not None:
            if reseat_index <= start_index:
                blockers.append(f"event_order_invalid_{start_label}_before_{reseat_label}")
            elif reseat_index - start_index < min_start_to_reseat_samples:
                blockers.append(f"event_spacing_too_short_{start_label}_to_{reseat_label}")
            elif min_start_to_reseat_seconds > 0:
                elapsed = numeric(summary.get("planned_interval_s")) * (reseat_index - start_index)
                if elapsed < min_start_to_reseat_seconds:
                    blockers.append(f"event_elapsed_too_short_{start_label}_to_{reseat_label}")
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


def best_candidate(records: list[tuple[Path, dict[str, Any]]], predicate, blocker_fn) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for path, summary in records:
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
            "min_accepted_sample_delta": summary.get("min_accepted_sample_delta"),
            "max_disconnect_delta": summary.get("max_disconnect_delta"),
            "max_hr_continuity_delta": summary.get("max_hr_continuity_delta"),
        })
    if not candidates:
        return {"summary": "missing", "status": "missing", "blockers": ["missing_evidence"]}
    candidates.sort(key=lambda item: (item["status"] == "pass", -len(item["blockers"]), item["summary"]))
    return candidates[-1]


def evaluate(root: Path = DEFAULT_ROOT) -> dict[str, Any]:
    paths = latest_summaries(root)
    records, invalid_summaries = load_summary_records(paths)
    daytime = best_candidate(
        records,
        lambda summary, _path: str(summary.get("label", "")).startswith("rt-daytime-")
        or summary_duration_seconds(summary) >= MIN_DAYTIME_DURATION_SECONDS,
        daytime_blockers,
    )
    brief = best_candidate(
        records,
        lambda summary, _path: has_event(summary, "brief_contact_loss_reseat")
        or "brief-contact-loss" in str(summary.get("label", "")),
        lambda summary: stress_blockers(
            summary,
            "brief_contact_loss_reseat",
            start_label="brief_contact_loss_start",
            min_start_to_reseat_samples=1,
            min_start_to_reseat_seconds=30,
        ),
    )
    sustained = best_candidate(
        records,
        lambda summary, _path: has_event(summary, "sustained_silence_reseat")
        or "sustained-silence" in str(summary.get("label", "")),
        lambda summary: stress_blockers(
            summary,
            "sustained_silence_reseat",
            start_label="sustained_silence_start",
            min_start_to_reseat_samples=2,
            min_start_to_reseat_seconds=150,
            require_clean_stream=False,
            allow_small_churn=True,
        ),
    )
    app_switch = best_candidate(
        records,
        lambda summary, _path: "app-switch" in str(summary.get("label", ""))
        or "clock-switch" in str(summary.get("label", "")),
        app_switch_blockers,
    )
    sections = {
        "daytime_worn_monitor": daytime,
        "brief_contact_loss": brief,
        "sustained_silence_reseat": sustained,
        "app_switch": app_switch,
    }
    for name, section in sections.items():
        action = NEXT_ACTIONS.get(name, {})
        if action:
            section["next_command"] = action["command"]
            section["operator_action"] = action["operator_action"]
    blockers = [
        f"{name}:{blocker}"
        for name, section in sections.items()
        if section["status"] != "pass"
        for blocker in section.get("blockers", [])
    ]
    blockers.extend(f"invalid_summary:{item['summary']}" for item in invalid_summaries)
    return {
        "status": "pass" if not blockers else "incomplete",
        "root": str(root),
        "generated_at": utc_now(),
        "summary_count": len(paths),
        "valid_summary_count": len(records),
        "invalid_summaries": invalid_summaries,
        "requirements": sections,
        "blockers": blockers,
    }


def markdown_summary(report: dict[str, Any]) -> str:
    def metric(section: dict[str, Any], key: str) -> Any:
        value = section.get(key)
        return "missing" if value is None else value

    lines = [
        "# Realtime BLE Validation Audit",
        "",
        f"- Status: `{report['status']}`",
        f"- Evidence root: `{report['root']}`",
        f"- Generated at: `{report.get('generated_at', 'missing')}`",
        f"- Summaries inspected: `{report.get('summary_count', 'missing')}`",
        f"- Valid summaries: `{report.get('valid_summary_count', report.get('summary_count', 'missing'))}`",
        f"- Invalid summaries: `{len(report.get('invalid_summaries', []))}`",
        "",
        "## Requirements",
    ]
    for name, section in report["requirements"].items():
        lines.extend([
            f"- `{name}`: `{section['status']}`",
            f"  - Summary: `{section['summary']}`",
            f"  - Blockers: `{', '.join(section.get('blockers', [])) or 'none'}`",
        ])
        if section["summary"] != "missing":
            lines.append(
                "  - Evidence: "
                f"samples=`{metric(section, 'samples')}`, "
                f"duration_s=`{metric(section, 'duration_s')}`, "
                f"min_raw_delta=`{metric(section, 'min_raw_notification_delta')}`, "
                f"min_accepted_delta=`{metric(section, 'min_accepted_sample_delta')}`, "
                f"max_disconnect_delta=`{metric(section, 'max_disconnect_delta')}`, "
                f"max_hr_continuity_delta=`{metric(section, 'max_hr_continuity_delta')}`"
            )
        if section["status"] != "pass":
            lines.extend([
                f"  - Next command: `{section.get('next_command', 'missing')}`",
                f"  - Operator action: {section.get('operator_action', 'missing')}",
            ])
    invalid = report.get("invalid_summaries", [])
    if invalid:
        lines.extend(["", "## Invalid Summaries"])
        for item in invalid[:10]:
            lines.append(f"- `{item.get('summary', 'missing')}`: `{item.get('error', 'unknown')}`")
        if len(invalid) > 10:
            lines.append(f"- ... `{len(invalid) - 10}` more")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--out", type=Path, default=None, help="Optional path to write the JSON or Markdown audit report.")
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Exit 0 after writing/printing an incomplete report. Use only for archiving snapshots, not as a completion gate.",
    )
    args = parser.parse_args()

    report = evaluate(args.root)
    output = markdown_summary(report) if args.markdown else json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out is not None:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding="utf-8")
    if args.markdown:
        print(output, end="")
    else:
        print(output, end="")
    return 0 if report["status"] == "pass" or args.allow_incomplete else 1


if __name__ == "__main__":
    raise SystemExit(main())
