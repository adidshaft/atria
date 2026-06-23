#!/usr/bin/env python3
"""Audit Atria realtime BLE validation evidence against docs/15."""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path("logs/live-device/realtime-ble-monitor")
MIN_DAYTIME_DURATION_SECONDS = 2 * 60 * 60
MIN_DAYTIME_SAMPLES = 61
MIN_APP_SWITCH_LIFECYCLE_COMMIT = "2a0491d"
EXPECTED_OPERATOR_ACTIONS = {
    "app_switch_background": "Switch away from Atria now and keep another app foregrounded.",
    "app_switch_return": "Return to Atria now.",
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
            "--label rt-app-switch-$(date -u +%Y%m%dT%H%M%SZ) --pull-state --audit-snapshot "
            "--event 1:app_switch_background --event 2:app_switch_return"
        ),
        "operator_action": "At sample index=1, foreground another app; at sample index=2, return to Atria.",
    },
}

COEXISTENCE_ACTION = {
    "command": (
        "./pull_atria_state.sh --device 3803F5B6-1666-56D3-A71A-62F131F6CE3B "
        "--bundle-id com.adidshaft.atria "
        "--evidence-dir logs/live-device/realtime-ble-monitor/whoop-cleared-final-$(date -u +%Y%m%dT%H%M%SZ) "
        "&& python3 tools/audit_realtime_ble_validation.py --markdown"
    ),
    "operator_action": (
        "Close, disable, or uninstall the official WHOOP app/widget first; then "
        "confirm the final state pull reports official_whoop_coexistence_risk=0. "
        "If WHOOP is intentionally kept installed/running, treat the next run as "
        "a dedicated coexistence proof rather than ordinary completion evidence."
    ),
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


def range_loss_backfill_proven(fields: dict[str, Any]) -> bool:
    reason = fields.get("offline_range_loss_backfill_reason")
    pending = str(fields.get("offline_range_loss_backfill_pending", ""))
    started_age = numeric(fields.get("offline_range_loss_backfill_started_age_s"))
    requested_age = numeric(fields.get("offline_range_loss_backfill_requested_age_s"))
    status = fields.get("offline_sync_last_status")
    completed_or_running = (
        pending in {"0", "false", "False"}
        and status in {"starting", "archived", "no_rows"}
        and started_age >= 0
    )
    armed_or_deferred = pending in {"1", "true", "True"} and status in {"armed", "deferred_live_link"}
    return (
        reason == "long_wear_range_loss"
        and requested_age >= 0
        and (completed_or_running or armed_or_deferred)
    )


def official_whoop_coexistence_detected(fields: dict[str, Any]) -> bool:
    return (
        str(fields.get("official_whoop_coexistence_risk", "")).lower() in {"1", "true", "yes"}
        or fields.get("official_whoop_process_status") == "running"
        or numeric(fields.get("official_whoop_process_count")) > 0
        or str(fields.get("official_whoop_main_process", "")).lower() in {"1", "true", "yes"}
        or str(fields.get("official_whoop_widget_process", "")).lower() in {"1", "true", "yes"}
    )


def continuity_checkpoint_duration(fields: dict[str, Any]) -> int:
    if fields.get("link_last_auto_save_status") != "checkpointed_continuity":
        return 0
    return numeric(fields.get("link_last_auto_save_duration_s"))


def continuity_checkpoint_samples(fields: dict[str, Any]) -> int:
    if fields.get("link_last_auto_save_status") != "checkpointed_continuity":
        return 0
    return numeric(fields.get("link_last_auto_save_samples"))


def app_switch_blockers(summary: dict[str, Any], summary_path: Path | None = None) -> list[str]:
    blockers = base_stream_blockers(summary)
    blockers.extend(audit_snapshot_blockers(summary, summary_path))
    blockers.extend(state_pull_blockers(summary, summary_path))
    if not has_event(summary, "app_switch_background"):
        blockers.append("missing_event_app_switch_background")
    if not has_event(summary, "app_switch_return"):
        blockers.append("missing_event_app_switch_return")
    start_index = event_sample_index(summary, "app_switch_background")
    return_index = event_sample_index(summary, "app_switch_return")
    if not has_operator_action(summary, "app_switch_background", start_index):
        blockers.append("missing_operator_action_app_switch_background")
    if not has_operator_action(summary, "app_switch_return", return_index):
        blockers.append("missing_operator_action_app_switch_return")
    if start_index is not None and return_index is not None:
        if return_index <= start_index:
            blockers.append("event_order_invalid_app_switch_background_before_app_switch_return")
        elif numeric(summary.get("planned_interval_s")) * (return_index - start_index) < 90:
            blockers.append("event_elapsed_too_short_app_switch_background_to_app_switch_return")
    if not commit_includes(summary.get("git_commit"), MIN_APP_SWITCH_LIFECYCLE_COMMIT):
        blockers.append("app_switch_evidence_before_disconnect_continuity_fix")
    return blockers


def state_fields(summary: dict[str, Any]) -> dict[str, Any]:
    state = summary.get("state_pull")
    if not isinstance(state, dict):
        return {}
    fields = state.get("fields")
    return fields if isinstance(fields, dict) else {}


def state_summary_file(summary: dict[str, Any], summary_path: Path | None = None) -> Path | None:
    state = summary.get("state_pull")
    if not isinstance(state, dict):
        return None
    summary_file = state.get("summary_file")
    if not summary_file:
        return None
    run_dir = summary_path.parent if summary_path else Path.cwd()
    state_file = resolve_run_artifact(summary_file, run_dir)
    return state_file if state_file and state_file.exists() else None


def enriched_state_fields(summary: dict[str, Any], summary_path: Path | None = None) -> dict[str, Any]:
    fields = dict(state_fields(summary))
    if all(key in fields for key in (
        "link_last_auto_save_status",
        "link_last_auto_save_samples",
        "link_last_auto_save_duration_s",
    )):
        return fields
    state_file = state_summary_file(summary, summary_path)
    if state_file is None:
        return fields
    prefs_path = state_file.parent / "preferences.plist"
    if not prefs_path.exists():
        return fields
    try:
        with prefs_path.open("rb") as handle:
            prefs = plistlib.load(handle)
    except Exception:
        return fields
    fields.setdefault("link_last_auto_save_status", prefs.get("whoop.link.lastAutoSaveStatus") or "none")
    fields.setdefault("link_last_auto_save_samples", str(int(prefs.get("whoop.link.lastAutoSaveSamples") or 0)))
    fields.setdefault("link_last_auto_save_duration_s", str(int(prefs.get("whoop.link.lastAutoSaveDuration") or 0)))
    return fields


def state_pull_blockers(summary: dict[str, Any], summary_path: Path | None = None) -> list[str]:
    state = summary.get("state_pull")
    if not isinstance(state, dict) or state.get("status") != "ok":
        return ["missing_ok_state_pull"]
    if not state.get("summary_file"):
        return ["state_pull_summary_file_missing"]
    state_file = state_summary_file(summary, summary_path)
    if state_file is None:
        return ["state_pull_summary_file_not_found"]
    fields = enriched_state_fields(summary, summary_path)
    if fields.get("file_durability_status") not in {"saved_sessions_present", "saved_sessions_preserved"}:
        return ["file_durability_not_proven"]
    return []


def resolve_run_artifact(path_value: object, run_dir: Path) -> Path | None:
    if not path_value:
        return None
    artifact_path = Path(str(path_value))
    if artifact_path.is_absolute():
        return artifact_path
    cwd_relative = (Path.cwd() / artifact_path).resolve()
    if cwd_relative.exists():
        return cwd_relative
    return run_dir / artifact_path


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def run_artifact_scope_blockers(summary: dict[str, Any], summary_path: Path) -> list[str]:
    blockers: list[str] = []
    run_dir = summary_path.parent
    state = summary.get("state_pull")
    if isinstance(state, dict) and state.get("summary_file"):
        state_file = resolve_run_artifact(state.get("summary_file"), run_dir)
        if state_file and state_file.exists() and not is_relative_to(state_file, run_dir):
            blockers.append("state_pull_summary_file_outside_run")
    snapshot = summary.get("audit_snapshot")
    if isinstance(snapshot, dict) and snapshot.get("path"):
        audit_file = resolve_run_artifact(snapshot.get("path"), run_dir)
        if audit_file and audit_file.exists() and not is_relative_to(audit_file, run_dir):
            blockers.append("audit_snapshot_file_outside_run")
    return blockers


def audit_snapshot_blockers(summary: dict[str, Any], summary_path: Path | None = None) -> list[str]:
    snapshot = summary.get("audit_snapshot")
    if not isinstance(snapshot, dict):
        return ["missing_audit_snapshot"]
    if snapshot.get("status") not in {"pass", "incomplete"}:
        return ["audit_snapshot_status_missing"]
    snapshot_path = snapshot.get("path")
    if not snapshot_path:
        return ["audit_snapshot_path_missing"]
    run_dir = summary_path.parent if summary_path else Path.cwd()
    audit_file = resolve_run_artifact(snapshot_path, run_dir)
    if audit_file is None or not audit_file.exists():
        return ["audit_snapshot_file_missing"]
    if numeric(snapshot.get("summary_count")) <= 0:
        return ["audit_snapshot_summary_count_missing"]
    return []


def daytime_blockers(summary: dict[str, Any], summary_path: Path | None = None) -> list[str]:
    blockers: list[str] = []
    if summary.get("worn_expected") is False:
        blockers.append("monitor_ran_not_worn")
    if summary.get("status") != "pass":
        blockers.append("summary_status_not_pass")
    flags = summary.get("flags") or []
    disconnect_delta = numeric(summary.get("max_disconnect_delta"))
    fields = enriched_state_fields(summary, summary_path)
    backfill_proven = range_loss_backfill_proven(fields)
    coexistence_detected = official_whoop_coexistence_detected(fields)
    continuity_duration = max(
        numeric(fields.get("active_journal_duration_s")),
        continuity_checkpoint_duration(fields),
    )
    continuity_samples = max(
        numeric(fields.get("active_journal_samples")),
        continuity_checkpoint_samples(fields),
    )
    if flags and not (disconnect_delta > 0 and backfill_proven and set(flags).issubset({"NO_NEW_DATA"})):
        blockers.append("summary_flags_present")
    if numeric(summary.get("min_raw_notification_delta")) <= 0 and not (disconnect_delta > 0 and backfill_proven):
        blockers.append("no_positive_raw_delta_on_every_tick")
    if (
        "min_accepted_sample_delta" in summary
        and numeric(summary.get("min_accepted_sample_delta")) <= 0
        and not (disconnect_delta > 0 and backfill_proven)
    ):
        blockers.append("no_positive_accepted_delta_on_every_tick")
    if disconnect_delta != 0 and not backfill_proven:
        blockers.append("disconnect_delta_without_range_loss_backfill")
    if numeric(summary.get("max_hr_continuity_delta")) != 0:
        blockers.append("hr_continuity_delta_nonzero")
    blockers.extend(audit_snapshot_blockers(summary, summary_path))
    duration = summary_duration_seconds(summary)
    if duration < MIN_DAYTIME_DURATION_SECONDS:
        blockers.append("daytime_monitor_under_2h")
    if numeric(summary.get("samples")) < MIN_DAYTIME_SAMPLES:
        blockers.append("daytime_monitor_too_few_samples")
    state_blockers = state_pull_blockers(summary, summary_path)
    if state_blockers:
        blockers.extend(state_blockers)
        return blockers
    if fields.get("active_journal_freshness") != "fresh":
        blockers.append("active_journal_not_fresh")
    if fields.get("active_journal_continuity_status") != "active":
        blockers.append("active_journal_not_active")
    if continuity_duration < MIN_DAYTIME_DURATION_SECONDS:
        blockers.append("active_journal_duration_under_2h")
    if continuity_samples < MIN_DAYTIME_SAMPLES:
        blockers.append("active_journal_too_few_samples")
    if coexistence_detected:
        blockers.append("official_whoop_coexistence_risk_present")
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
    summary_path: Path | None = None,
    start_label: str | None = None,
    min_start_to_reseat_samples: int = 1,
    min_start_to_reseat_seconds: float = 0,
    require_clean_stream: bool = True,
    allow_small_churn: bool = False,
) -> list[str]:
    blockers = base_stream_blockers(summary) if require_clean_stream else []
    blockers.extend(audit_snapshot_blockers(summary, summary_path))
    blockers.extend(state_pull_blockers(summary, summary_path))
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
        blockers = blocker_fn(summary, path)
        blockers.extend(run_artifact_scope_blockers(summary, path))
        fields = state_fields(summary)
        audit_snapshot = summary.get("audit_snapshot")
        audit_snapshot = audit_snapshot if isinstance(audit_snapshot, dict) else {}
        state_pull = summary.get("state_pull")
        state_pull = state_pull if isinstance(state_pull, dict) else {}
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
            "state_pull_status": state_pull.get("status"),
            "file_durability_status": fields.get("file_durability_status"),
            "active_journal_freshness": fields.get("active_journal_freshness"),
            "active_journal_continuity_status": fields.get("active_journal_continuity_status"),
            "audit_snapshot_status": audit_snapshot.get("status"),
            "audit_snapshot_summary_count": audit_snapshot.get("summary_count"),
        })
    if not candidates:
        return {
            "summary": "missing",
            "status": "missing",
            "blockers": ["missing_evidence"],
            "candidate_count": 0,
        }
    candidates.sort(key=lambda item: (item["status"] == "pass", -len(item["blockers"]), item["summary"]))
    best = candidates[-1]
    best["candidate_count"] = len(candidates)
    return best


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
        lambda summary, path: stress_blockers(
            summary,
            "brief_contact_loss_reseat",
            summary_path=path,
            start_label="brief_contact_loss_start",
            min_start_to_reseat_samples=1,
            min_start_to_reseat_seconds=30,
        ),
    )
    sustained = best_candidate(
        records,
        lambda summary, _path: has_event(summary, "sustained_silence_reseat")
        or "sustained-silence" in str(summary.get("label", "")),
        lambda summary, path: stress_blockers(
            summary,
            "sustained_silence_reseat",
            summary_path=path,
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
        if (
            name == "daytime_worn_monitor"
            and section.get("blockers") == ["official_whoop_coexistence_risk_present"]
        ):
            action = COEXISTENCE_ACTION
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
            f"  - Candidates: `{section.get('candidate_count', 'missing')}`",
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
            lines.append(
                "  - Continuity: "
                f"state_pull=`{metric(section, 'state_pull_status')}`, "
                f"file_durability=`{metric(section, 'file_durability_status')}`, "
                f"active_journal=`{metric(section, 'active_journal_continuity_status')}`, "
                f"freshness=`{metric(section, 'active_journal_freshness')}`, "
                f"audit_snapshot=`{metric(section, 'audit_snapshot_status')}`, "
                f"audit_summaries=`{metric(section, 'audit_snapshot_summary_count')}`"
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
