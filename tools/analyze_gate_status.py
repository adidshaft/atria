#!/usr/bin/env python3
"""Reduce ATRIADBG gate_status logs into an ordered blocker table."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SUMMARY_RE = re.compile(r"ATRIADBG gate_status_summary (?P<body>.*)$")
GATE_RE = re.compile(r"ATRIADBG gate_status gate=(?P<gate>\S+) status=(?P<status>\S+) evidence=(?P<evidence>.*)$")
LOCAL_RE = re.compile(r"ATRIADBG local_status (?P<body>.*)$")
DAILY_SUMMARY_RE = re.compile(r"ATRIADBG daily_rollup_summary (?P<body>.*)$")
TREND_SUMMARY_RE = re.compile(r"ATRIADBG trend_summary (?P<body>.*)$")
TREND_RE = re.compile(r"ATRIADBG trend_window (?P<body>.*)$")
STRAIN_VALIDATION_RE = re.compile(r"ATRIADBG strain_validation (?P<body>.*)$")
WORKOUT_VALIDATION_RE = re.compile(r"ATRIADBG workout_validation (?P<body>.*)$")
SLEEP_VALIDATION_RE = re.compile(r"ATRIADBG sleep_validation (?P<body>.*)$")
RR_REFERENCE_PACKAGE_RE = re.compile(r"ATRIADBG rr_reference_package (?P<body>.*)$")
RR_REFERENCE_VALIDATION_RE = re.compile(r"ATRIADBG rr_reference_validation (?P<body>.*)$")
HR_REFERENCE_PACKAGE_RE = re.compile(r"ATRIADBG hr_reference_package (?P<body>.*)$")
HR_REFERENCE_VALIDATION_RE = re.compile(r"ATRIADBG hr_reference_validation (?P<body>.*)$")
BACKUP_VERIFY_RE = re.compile(r"ATRIADBG session_backup_verify (?P<body>.*)$")
WIDGET_RE = re.compile(r"ATRIADBG widget_snapshot (?P<body>.*)$")
HEALTHKIT_EXPORT_RE = re.compile(r"ATRIADBG healthkit_export (?P<body>.*)$")
HEALTHKIT_EXPORT_VERIFY_RE = re.compile(r"ATRIADBG healthkit_export_verify (?P<body>.*)$")
HEALTHKIT_REFERENCE_AUDIT_RE = re.compile(r"ATRIADBG healthkit_reference_audit (?P<body>.*)$")
KV_RE = re.compile(r"(?<![A-Za-z0-9_])_?([A-Za-z][A-Za-z0-9_]*)=")
BARE_KV_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_]*)=(.*)$")
GATE_ORDER = ["local", "A", "B", "C", "D", "E", "F", "G", "H"]
HISTORICAL_ARCHIVE_KEYS = {
    "rows",
    "schemas",
    "layouts",
    "payload_lengths",
    "raw_payload_rows",
    "undecodable_rows",
    "metric_usable_rows",
    "current_session_usable_rows",
    "whoof_rr_values",
    "k_rr_values",
    "candidate_rr_values",
    "hist_versions",
    "noop_historical_gravity_rows",
    "noop_historical_gravity_validated_rows",
    "unix_first",
    "unix_last",
    "clock_correlation_rows",
    "clock_correlation_statuses",
    "clock_offset_s",
    "clock_corrected_unix_first",
    "clock_corrected_unix_last",
    "archive_current_session_overlap",
    "archive_current_session_ready",
    "archive_overlap_reason",
    "archive_persisted",
    "metric_ready",
    "current_session_ready",
    "stored_transfer_verified",
    "codec_ok_frames",
    "codec_bad_frames",
    "gate_h_protocol_exit_ready",
    "gate_h_current_session_metric_ready",
    "gate_h_reason",
    "ready",
    "interpretation",
}


def parse_kv(text: str) -> dict[str, str]:
    matches = list(KV_RE.finditer(text))
    parsed: dict[str, str] = {}
    for index, match in enumerate(matches):
        key = match.group(1)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        value = text[start:end].strip().strip(";").replace("_", " ")
        parsed[key] = value
    return parsed


def parse_evidence(text: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in text.split(";"):
        part = part.strip().lstrip("_")
        if not part or "=" not in part:
            continue
        key, value = part.split("=", 1)
        parsed[key.strip()] = value.strip().replace("_", " ")
    return parsed


def load_status(path: Path) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    summary: dict[str, str] = {}
    gates: dict[str, dict[str, str]] = {}
    fallback: dict[str, dict[str, str]] = {
        "local_status": {},
        "daily_summary": {},
        "trend_summary": {},
        "trend90": {},
        "strain_validation": {},
        "workout_validation": {},
        "sleep_validation": {},
        "rr_reference_package": {},
        "rr_reference_validation": {},
        "hr_reference_package": {},
        "hr_reference_validation": {},
        "backup_verify": {},
        "widget": {},
        "healthkit_export": {},
        "healthkit_export_verify": {},
        "healthkit_reference_audit": {},
        "historical_archive": {},
    }
    for line in path.read_text(errors="replace").splitlines():
        if match := SUMMARY_RE.search(line):
            summary = parse_kv(match.group("body"))
            continue
        if match := GATE_RE.search(line):
            gate = match.group("gate")
            gates[gate] = {
                "status": match.group("status"),
                **parse_evidence(match.group("evidence")),
            }
            continue
        if match := LOCAL_RE.search(line):
            fallback["local_status"] = parse_kv(match.group("body"))
            continue
        if match := DAILY_SUMMARY_RE.search(line):
            fallback["daily_summary"] = parse_kv(match.group("body"))
            continue
        if match := TREND_SUMMARY_RE.search(line):
            fallback["trend_summary"] = parse_kv(match.group("body"))
            continue
        if match := TREND_RE.search(line):
            trend = parse_kv(match.group("body"))
            if trend.get("days") == "90":
                fallback["trend90"] = trend
            continue
        if match := STRAIN_VALIDATION_RE.search(line):
            fallback["strain_validation"] = parse_kv(match.group("body"))
            continue
        if match := WORKOUT_VALIDATION_RE.search(line):
            fallback["workout_validation"] = parse_kv(match.group("body"))
            continue
        if match := SLEEP_VALIDATION_RE.search(line):
            fallback["sleep_validation"] = parse_kv(match.group("body"))
            continue
        if match := RR_REFERENCE_PACKAGE_RE.search(line):
            fallback["rr_reference_package"] = parse_kv(match.group("body"))
            continue
        if match := RR_REFERENCE_VALIDATION_RE.search(line):
            fallback["rr_reference_validation"] = parse_kv(match.group("body"))
            continue
        if match := HR_REFERENCE_PACKAGE_RE.search(line):
            fallback["hr_reference_package"] = parse_kv(match.group("body"))
            continue
        if match := HR_REFERENCE_VALIDATION_RE.search(line):
            fallback["hr_reference_validation"] = parse_kv(match.group("body"))
            continue
        if match := BACKUP_VERIFY_RE.search(line):
            fallback["backup_verify"] = parse_kv(match.group("body"))
            continue
        if match := WIDGET_RE.search(line):
            fallback["widget"] = parse_kv(match.group("body"))
            continue
        if match := HEALTHKIT_EXPORT_VERIFY_RE.search(line):
            fallback["healthkit_export_verify"] = parse_kv(match.group("body"))
            continue
        if match := HEALTHKIT_REFERENCE_AUDIT_RE.search(line):
            fallback["healthkit_reference_audit"] = parse_kv(match.group("body"))
            continue
        if match := HEALTHKIT_EXPORT_RE.search(line):
            fallback["healthkit_export"] = parse_kv(match.group("body"))
            continue
        if match := BARE_KV_RE.match(line.strip()):
            key = match.group(1)
            if key in HISTORICAL_ARCHIVE_KEYS:
                fallback["historical_archive"][key] = match.group(2).strip()
    if not gates:
        summary, gates = synthesize_fallback_status(summary, fallback)
    if "E.deep" in gates and "E" in gates:
        gates["E"] = {**gates["E"], **gates["E.deep"], "status": gates["E"].get("status", gates["E.deep"].get("status", "partial"))}
    return summary, gates


def synthesize_fallback_status(
    summary: dict[str, str],
    fallback: dict[str, dict[str, str]],
) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    local = fallback["local_status"]
    if not local:
        trend90 = fallback["trend90"]
        trend_summary = fallback["trend_summary"]
        strain_validation = fallback["strain_validation"]
        workout_validation = fallback["workout_validation"]
        sleep_validation = fallback["sleep_validation"]
        rr_package = fallback["rr_reference_package"]
        rr_validation = fallback["rr_reference_validation"]
        hr_package = fallback["hr_reference_package"]
        hr_validation = fallback["hr_reference_validation"]
        historical_archive = fallback["historical_archive"]
        widget = fallback["widget"]
        focused_reference_gates: dict[str, dict[str, str]] = {}
        if rr_package or rr_validation:
            package_ready = "1" if rr_package.get("status") == "ok" else "0"
            validation_passed = (
                rr_validation.get("gate_b_pass", "0") == "1"
                and rr_validation.get("reference_validated", "0") == "1"
            )
            reference_present = "1" if rr_validation.get("external_reference", "0") == "1" else "0"
            reference_validated = "1" if validation_passed else "0"
            if not summary:
                summary = {
                    "sessions": rr_validation.get("sessions", rr_package.get("sessions", "missing")),
                    "days": "missing",
                    "rest_hr": "missing",
                    "max_hr": "missing",
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            focused_reference_gates["B"] = {
                "status": "ready" if validation_passed else "reference_pending",
                "rr_reference_package_status": rr_package.get("status", "not_checked"),
                "saved_rr_ready": package_ready,
                "saved_rr_samples": rr_package.get("raw", rr_validation.get("whoop_raw", "0")),
                "saved_rr_kept": rr_package.get("kept", rr_validation.get("whoop_kept", "0")),
                "saved_rr_confidence": rr_package.get("conf", rr_validation.get("whoop_conf", "0")),
                "saved_rr_max_gap_s": rr_package.get("max_rr_gap_s", rr_validation.get("whoop_gap_s", "0")),
                "saved_rr_best_rmssd": rr_package.get("rmssd", rr_validation.get("strap_rmssd", "0")),
                "saved_rr_best_label": rr_package.get("session_label", "missing"),
                "reference_validation_status": rr_validation.get("status", "not_checked"),
                "reference_validation_reason": rr_validation.get("reason", "not_checked"),
                "reference_ready": rr_validation.get("reference_ready", "0"),
                "reference_rmssd": rr_validation.get("reference_rmssd", "0"),
                "rmssd_delta_ms": rr_validation.get("rmssd_delta_ms", "missing"),
                "external_rr_reference": "present" if reference_present == "1" else "missing",
                "external_rr_reference_required": "1",
                "reference_validated": reference_validated,
                "gate_b_pass": "1" if validation_passed else "0",
                "reference_action": rr_validation.get("action", "provide_independent_rr_ibi_recording"),
                "reference_path": rr_package.get("reference_path", "Documents/atria-reference/rr-reference.csv"),
            }
        if hr_package or hr_validation:
            package_ready = "1" if hr_package.get("status") == "ok" else "0"
            validation_passed = (
                hr_validation.get("gate_d_pass", "0") == "1"
                and hr_validation.get("reference_validated", "0") == "1"
            )
            reference_present = "1" if hr_validation.get("external_reference", "0") == "1" else "0"
            validation_reason = hr_validation.get("reason", "not_checked")
            if validation_passed:
                primary_blocker = "none"
            elif validation_reason != "not_checked":
                primary_blocker = validation_reason
            elif package_ready == "1":
                primary_blocker = "external_hr_reference_missing"
            else:
                primary_blocker = hr_package.get("reason", "hr_reference_package_not_ready")
            if not summary:
                summary = {
                    "sessions": hr_validation.get("sessions", hr_package.get("sessions", "missing")),
                    "days": "missing",
                    "rest_hr": hr_package.get("resting_hr", "missing"),
                    "max_hr": "missing",
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            focused_reference_gates["D"] = {
                "status": "ready" if validation_passed else "partial",
                "primary_blocker": primary_blocker,
                "hr_reference_package_status": hr_package.get("status", "not_checked"),
                "saved_hr_ready": package_ready,
                "strap_samples": hr_package.get("samples", hr_validation.get("strap_samples", "0")),
                "whoop_duration_s": hr_package.get("duration_s", hr_validation.get("duration_s", "0")),
                "whoop_observed_s": hr_package.get("observed_s", "0"),
                "whoop_coverage_percent": hr_package.get("coverage_percent", "0"),
                "whoop_avg_hr": hr_package.get("avg_hr", "missing"),
                "whoop_peak_hr": hr_package.get("peak_hr", hr_validation.get("whoop_peak_hr", "missing")),
                "rest_hr": hr_package.get("resting_hr", hr_validation.get("strap_resting_hr", "missing")),
                "reference_validation_status": hr_validation.get("status", "not_checked"),
                "reference_validation_reason": validation_reason,
                "reference_samples": hr_validation.get("reference_samples", "0"),
                "reference_pairs": hr_validation.get("pairs", "0"),
                "mean_delta_bpm": hr_validation.get("mean_delta_bpm", "missing"),
                "median_delta_bpm": hr_validation.get("median_delta_bpm", "missing"),
                "max_delta_bpm": hr_validation.get("max_delta_bpm", "missing"),
                "within_tolerance_percent": hr_validation.get("within_tolerance_percent", "0"),
                "external_hr_reference": "present" if reference_present == "1" else "missing",
                "external_hr_reference_required": "1",
                "external_hr_reference_validated": "1" if validation_passed else "0",
                "reference_validated": "1" if validation_passed else "0",
                "gate_d_pass": "1" if validation_passed else "0",
                "reference_action": hr_validation.get("action", "provide_independent_chest_strap_hr_recording"),
            }
        if focused_reference_gates:
            return summary, focused_reference_gates
        if historical_archive:
            rows = historical_archive.get("rows", "0")
            raw_rows = historical_archive.get("raw_payload_rows", "0")
            undecodable = historical_archive.get("undecodable_rows", "missing")
            archive_persisted = historical_archive.get("archive_persisted", "0")
            stored_verified = historical_archive.get("stored_transfer_verified", "0")
            codec_ok = historical_archive.get("codec_ok_frames", "0")
            codec_bad = historical_archive.get("codec_bad_frames", "missing")
            protocol_ready = historical_archive.get("gate_h_protocol_exit_ready")
            if protocol_ready is None:
                protocol_ready_bool = (
                    archive_persisted == "1"
                    and stored_verified == "1"
                    and int_or_zero(codec_ok) > 0
                    and int_or_zero(codec_bad, default=-1) == 0
                    and int_or_zero(raw_rows) > 0
                    and int_or_zero(undecodable, default=-1) == 0
                )
                protocol_ready = "1" if protocol_ready_bool else "0"
            current_ready = historical_archive.get(
                "gate_h_current_session_metric_ready",
                historical_archive.get("current_session_ready", "0"),
            )
            metric_ready = historical_archive.get("metric_ready", "0")
            if not summary:
                summary = {
                    "sessions": historical_archive.get("saved_sessions", "missing"),
                    "days": "missing",
                    "rest_hr": "missing",
                    "max_hr": "missing",
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            gates = {
                "H": {
                    "status": "ready" if protocol_ready == "1" else "partial",
                    "historical_download_validated": protocol_ready,
                    "gate_h_protocol_exit_ready": protocol_ready,
                    "historical_archive_local": "1" if int_or_zero(rows) > 0 else "0",
                    "historical_archive_parse_ok": "1" if int_or_zero(undecodable, default=-1) == 0 else "0",
                    "historical_archive_rows": rows,
                    "historical_archive_schemas": historical_archive.get("schemas", "missing"),
                    "historical_archive_layouts": historical_archive.get("layouts", "missing"),
                    "historical_archive_raw_payload_rows": raw_rows,
                    "historical_archive_undecodable_rows": undecodable,
                    "historical_archive_metric_usable": historical_archive.get("metric_usable_rows", metric_ready),
                    "historical_archive_current_usable": historical_archive.get("current_session_usable_rows", current_ready),
                    "historical_archive_unix_first": historical_archive.get("unix_first", "missing"),
                    "historical_archive_unix_last": historical_archive.get("unix_last", "missing"),
                    "historical_archive_corrected_unix_first": historical_archive.get("clock_corrected_unix_first", "missing"),
                    "historical_archive_corrected_unix_last": historical_archive.get("clock_corrected_unix_last", "missing"),
                    "historical_archive_gravity_rows": historical_archive.get("noop_historical_gravity_rows", "0"),
                    "historical_archive_gravity_validated_rows": historical_archive.get("noop_historical_gravity_validated_rows", "0"),
                    "historical_archive_current_overlap": historical_archive.get("archive_current_session_overlap", "0"),
                    "historical_archive_overlap_reason": historical_archive.get("archive_overlap_reason", historical_archive.get("gate_h_reason", "missing")),
                    "historical_archive_persisted": archive_persisted,
                    "stored_transfer_verified": stored_verified,
                    "codec_ok_frames": codec_ok,
                    "codec_bad_frames": codec_bad,
                    "historical_rr_metric_ready": "1" if metric_ready == "1" and current_ready == "1" else "0",
                    "historical_metric_fail_closed": "0" if metric_ready == "1" and current_ready == "1" else "1",
                    "new_sensor_validated": "0",
                }
            }
            return summary, gates
        if workout_validation or sleep_validation:
            sleep_status = sleep_validation.get("status", "not_checked")
            sleep_reason = sleep_validation.get("reason", "not_checked")
            workout_status = workout_validation.get("status", "not_checked")
            workout_reason = workout_validation.get("reason", "not_checked")
            sleep_checked = "1" if sleep_validation else "0"
            workout_checked = "1" if workout_validation else "0"
            sleep_ready = "1" if sleep_status == "ready" else "0"
            workout_ready = "1" if workout_status == "ready" else "0"
            if not summary:
                summary = {
                    "sessions": workout_validation.get("sessions", sleep_validation.get("sessions", "missing")),
                    "days": "missing",
                    "rest_hr": workout_validation.get("rest_hr", sleep_validation.get("rest_hr", "missing")),
                    "max_hr": workout_validation.get("max_hr", sleep_validation.get("max_hr", "missing")),
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            gates = {
                "E": {
                    "status": "ready" if sleep_ready == "1" and workout_ready == "1" else "partial",
                    "focused_validation": "1",
                    "sleep_validation_checked": sleep_checked,
                    "sleep_validation_status": sleep_status,
                    "sleep_days": "1" if sleep_validation and code_value(sleep_reason) != "no_saved_session" else "0",
                    "sleep_state": "ready" if sleep_ready == "1" else "learning",
                    "sleep_ready": sleep_ready,
                    "sleep_blocker": "none" if sleep_ready == "1" else sleep_reason,
                    "sleep_confidence": sleep_validation.get("confidence", "not_checked"),
                    "sleep_fallback_available": sleep_validation.get("fallback_available", "0"),
                    "sleep_fallback_source": sleep_validation.get("fallback_source", "none"),
                    "sleep_fallback_duration_s": sleep_validation.get("fallback_duration_s", sleep_validation.get("duration_s", "0")),
                    "sleep_fallback_chunks": sleep_validation.get("fallback_chunks", "0"),
                    "motion_validated": sleep_validation.get("motion_validated", "0"),
                    "motion_source": sleep_validation.get("motion_source", "not_checked"),
                    "workout_validation_checked": workout_checked,
                    "workout_validation_status": workout_status,
                    "workout_days": "1" if workout_ready == "1" else "0",
                    "workout_state": "ready" if workout_ready == "1" else "learning",
                    "workout_saved_ready": workout_ready,
                    "workout_near_miss": workout_validation.get("near_miss", "0"),
                    "workout_near_miss_reason": workout_validation.get("near_miss_reason", "none"),
                    "workout_best_source": workout_validation.get("source", "not_checked"),
                    "workout_best_blocker": "none" if workout_ready == "1" else workout_validation.get("primary_blocker", workout_reason),
                    "workout_best_stream_coverage_percent": workout_validation.get("stream_coverage_percent", "0"),
                    "workout_best_threshold_gap_bpm": workout_validation.get("threshold_gap_bpm", "0"),
                    "workout_best_duration_s": workout_validation.get("duration_s", "0"),
                    "workout_best_observed_s": workout_validation.get("observed_duration_s", "0"),
                    "workout_best_elevated_s": workout_validation.get("elevated_s", "0"),
                    "workout_best_longest_bout_s": workout_validation.get("longest_bout_s", "0"),
                    "workout_best_required_bout_s": workout_validation.get("required_bout_s", "0"),
                    "historical_gap_repair_status": "not_checked_focused_validation",
                    "historical_gap_repair_reason": "not_checked_focused_validation",
                }
            }
            return summary, gates
        if widget:
            app_group = widget.get("app_group", "0")
            widget_target = widget.get("widget_target", "0")
            complication_target = widget.get("complication_target", "0")
            widget_ready = app_group == "1" and widget_target == "1" and complication_target == "1"
            if not summary:
                summary = {
                    "sessions": "missing",
                    "days": "missing",
                    "rest_hr": widget.get("rhr", "missing"),
                    "max_hr": widget.get("max_hr", "missing"),
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            gates = {
                "G": {
                    "status": "metric_gated" if widget_ready else "partial",
                    "widget_storage": widget.get("storage", "missing"),
                    "widget_app_group": app_group,
                    "widget_target": widget_target,
                    "complication_target": complication_target,
                    "metric_blockers": "healthkit_hrv_reference_pending+healthkit_workout_learning",
                    "healthkit_readback_status": "not_checked_widget_snapshot_only",
                    "healthkit_entitlement": "not_checked_widget_snapshot_only",
                    "backup_available": "not_checked_widget_snapshot_only",
                    "recovery": widget.get("recovery", "learning"),
                    "recovery_confidence": widget.get("confidence", "learning"),
                    "hrv": widget.get("hrv", "learning"),
                    "strain": widget.get("strain", "0"),
                }
            }
            return summary, gates
        if strain_validation:
            if not summary:
                summary = {
                    "sessions": strain_validation.get("sessions", "missing"),
                    "days": strain_validation.get("days", "missing"),
                    "rest_hr": strain_validation.get("rest_hr", "missing"),
                    "max_hr": strain_validation.get("max_hr", "missing"),
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            gates = {
                "D": {
                    "status": "ready" if strain_validation.get("ready", "0") == "1" else "partial",
                    "primary_blocker": strain_validation.get("primary_blocker", "external_hr_rest_to_max_validation"),
                    "rest_to_max_ready": strain_validation.get("rest_to_max_ready", "0"),
                    "ready": strain_validation.get("ready", "0"),
                    "profile_max_hr": strain_validation.get("max_hr", "missing"),
                    "rest_hr": strain_validation.get("rest_hr", "missing"),
                    "stream_coverage_percent": strain_validation.get("stream_coverage_percent", "0"),
                    "max_hrr_percent": strain_validation.get("max_hrr_percent", "0"),
                    "high_z3_z4_s": strain_validation.get("high_z3_z4_s", "0"),
                    "external_hr_reference_validated": strain_validation.get("external_hr_reference_validated", "0"),
                    "strain": strain_validation.get("strain", "0"),
                }
            }
            return summary, gates
        if trend90:
            if not summary and trend_summary:
                summary = {
                    "sessions": trend_summary.get("sessions", "missing"),
                    "days": "missing",
                    "rest_hr": trend_summary.get("rest_hr", "missing"),
                    "max_hr": trend_summary.get("max_hr", "missing"),
                    "backup_current": "missing",
                    "healthkit_entitlement": "missing",
                    "healthkit_hr_samples": "missing",
                    "healthkit_workouts": "missing",
                }
            gates = {
                "F": {
                    "status": trend90.get("confidence", "learning"),
                    "trend90_coverage_days": trend90.get("coverage_days", "0"),
                    "trend90_required_coverage_days": trend90.get("required_coverage_days", "63"),
                    "trend90_coverage_percent": trend90.get("coverage_percent", "0"),
                    "trend_blockers": trend90.get("blockers", "coverage_below_70pct+hrv_reference_pending"),
                    "hrv_reference_gated": "1" if trend90.get("hrv_state", "reference_pending") == "reference_pending" else "0",
                    "trend_windows": trend_summary.get("windows", "missing"),
                    "trend_sessions": trend_summary.get("sessions", trend90.get("sessions", "0")),
                    "anomaly_flags": trend90.get("anomaly_flags", "none"),
                }
            }
            return summary, gates
        return summary, {}
    daily = fallback["daily_summary"]
    trend90 = fallback["trend90"]
    backup = fallback["backup_verify"]
    widget = fallback["widget"]
    rr_package = fallback["rr_reference_package"]
    rr_validation = fallback["rr_reference_validation"]
    hr_package = fallback["hr_reference_package"]
    hr_validation = fallback["hr_reference_validation"]
    healthkit_export = fallback["healthkit_export"]
    healthkit_export_verify = fallback["healthkit_export_verify"]
    healthkit_reference = fallback["healthkit_reference_audit"]
    if not summary and daily:
        summary = {
            "sessions": daily.get("sessions", "missing"),
            "days": daily.get("days", "missing"),
            "rest_hr": daily.get("rest_hr", "missing"),
            "max_hr": daily.get("max_hr", "missing"),
            "backup_current": backup.get("digest_match", "missing"),
            "healthkit_entitlement": "1" if healthkit_export else "missing",
            "healthkit_hr_samples": healthkit_export_verify.get(
                "readback_atria_hr_samples",
                healthkit_export.get("hr_samples", backup.get("current_hr_accepted", "missing")),
            ),
            "healthkit_workouts": healthkit_export.get("workouts", "missing"),
        }

    hrv_validated = local.get("hrv_validated_sessions", "0")
    hrv_baseline = local.get("hrv_baseline_samples", "0")
    historical_rows = local.get("historical_archive_rows", "0")
    historical_raw_ready = "1" if int_or_zero(historical_rows) > 0 else "0"
    widget_target = widget.get("widget_target", "0")
    complication_target = widget.get("complication_target", "0")
    rr_package_ready = "1" if rr_package.get("status") == "ok" else "0"
    rr_validation_passed = (
        rr_validation.get("gate_b_pass", "0") == "1"
        and rr_validation.get("reference_validated", "0") == "1"
    )
    rr_reference_validated = "1" if hrv_validated != "0" or rr_validation_passed else "0"
    hr_package_ready = "1" if hr_package.get("status") == "ok" else "0"
    hr_validation_passed = (
        hr_validation.get("gate_d_pass", "0") == "1"
        and hr_validation.get("reference_validated", "0") == "1"
    )
    hr_validation_reason = hr_validation.get("reason", "not_checked")
    if hr_validation_passed:
        gate_d_blocker = "none"
    elif hr_validation_reason != "not_checked":
        gate_d_blocker = hr_validation_reason
    elif hr_package_ready == "1":
        gate_d_blocker = "external_hr_reference_missing"
    else:
        gate_d_blocker = "external_hr_rest_to_max_validation"
    gates = {
        "local": {
            "status": "dashboard",
            "sleep_days": local.get("sleep_days", "0"),
            "sleep_state": local.get("sleep_state", "learning"),
            "workout_days": local.get("workout_days", "0"),
            "workout_state": local.get("workout_state", "learning"),
            "hrv_state": local.get("hrv_state", "reference_pending"),
            "hrv_validated_sessions": hrv_validated,
            "hrv_baseline_samples": hrv_baseline,
            "recovery_state": local.get("recovery_state", "learning"),
            "trend90_coverage_percent": local.get("trend90_coverage_percent", trend90.get("coverage_percent", "0")),
            "trend_state": local.get("trend_state", trend90.get("confidence", "learning")),
            "motion_source": local.get("motion_source", "unavailable"),
            "external_rr_reference": local.get("external_rr_reference", "missing"),
            "watchdog_no_data_recoveries": local.get("watchdog_no_data_recoveries", "0"),
            "watchdog_hr_continuity_recoveries": local.get("watchdog_hr_continuity_recoveries", "0"),
            "watchdog_accepted_hr_recoveries": local.get("watchdog_accepted_hr_recoveries", "0"),
            "watchdog_last_source": local.get("watchdog_last_source", "missing"),
            "watchdog_last_action": local.get("watchdog_last_action", "missing"),
        },
        "A": {
            "status": "runtime_required",
        },
        "B": {
            "status": "ready" if rr_validation_passed else ("reference_partial" if hrv_validated != "0" else "reference_pending"),
            "reference_validated": rr_reference_validated,
            "saved_rr_ready": rr_package_ready if rr_package else local.get("saved_rr_ready", "0"),
            "saved_rr_samples": rr_package.get("raw", rr_validation.get("whoop_raw", backup.get("current_rr_samples", "0"))),
            "saved_rr_kept": rr_package.get("kept", rr_validation.get("whoop_kept", "0")),
            "saved_rr_confidence": rr_package.get("conf", rr_validation.get("whoop_conf", "0")),
            "saved_rr_max_gap_s": rr_package.get("max_rr_gap_s", rr_validation.get("whoop_gap_s", "0")),
            "saved_rr_best_rmssd": rr_package.get("rmssd", rr_validation.get("strap_rmssd", local.get("saved_rr_best_rmssd", "0"))),
            "saved_rr_best_label": rr_package.get("session_label", local.get("saved_rr_best_label", "missing")),
            "rr_reference_package_status": rr_package.get("status", "not_checked"),
            "reference_validation_status": rr_validation.get("status", "not_checked"),
            "reference_validation_reason": rr_validation.get("reason", "not_checked"),
            "reference_ready": rr_validation.get("reference_ready", "0"),
            "reference_rmssd": rr_validation.get("reference_rmssd", "0"),
            "rmssd_delta_ms": rr_validation.get("rmssd_delta_ms", "missing"),
            "external_rr_reference": "present" if rr_validation.get("external_reference", "0") == "1" else local.get("external_rr_reference", "missing"),
            "external_rr_reference_required": "1",
            "gate_b_pass": "1" if rr_validation_passed else "0",
            "reference_action": rr_validation.get("action", "provide_independent_rr_ibi_recording"),
        },
        "C": {
            "status": "ready" if int_or_zero(hrv_baseline) >= 7 and hrv_validated != "0" else "learning",
            "validated_hrv_baseline": f"{hrv_baseline}/7",
            "latest_validated_hrv": "0" if hrv_validated == "0" else "present",
        },
        "D": {
            "status": "ready" if hr_validation_passed else "partial",
            "primary_blocker": gate_d_blocker,
            "profile_max_hr": daily.get("max_hr", "missing"),
            "rest_hr": hr_package.get("resting_hr", daily.get("rest_hr", "missing")),
            "hr_reference_package_status": hr_package.get("status", "not_checked"),
            "saved_hr_ready": hr_package_ready,
            "strap_samples": hr_package.get("samples", hr_validation.get("strap_samples", "0")),
            "whoop_duration_s": hr_package.get("duration_s", hr_validation.get("duration_s", "0")),
            "whoop_observed_s": hr_package.get("observed_s", "0"),
            "whoop_coverage_percent": hr_package.get("coverage_percent", "0"),
            "whoop_avg_hr": hr_package.get("avg_hr", "missing"),
            "whoop_peak_hr": hr_package.get("peak_hr", "missing"),
            "reference_validation_status": hr_validation.get("status", "not_checked"),
            "reference_validation_reason": hr_validation_reason,
            "reference_samples": hr_validation.get("reference_samples", "0"),
            "reference_pairs": hr_validation.get("pairs", "0"),
            "mean_delta_bpm": hr_validation.get("mean_delta_bpm", "missing"),
            "median_delta_bpm": hr_validation.get("median_delta_bpm", "missing"),
            "max_delta_bpm": hr_validation.get("max_delta_bpm", "missing"),
            "within_tolerance_percent": hr_validation.get("within_tolerance_percent", "0"),
            "external_hr_reference": "present" if hr_validation.get("external_reference", "0") == "1" else local.get("external_hr_reference", "missing"),
            "external_hr_reference_required": "1",
            "external_hr_reference_validated": "1" if hr_validation_passed else "0",
            "reference_validated": "1" if hr_validation_passed else "0",
            "gate_d_pass": "1" if hr_validation_passed else "0",
            "reference_action": hr_validation.get("action", "provide_independent_chest_strap_hr_recording"),
        },
        "E": {
            "status": "ready" if local.get("sleep_days", "0") != "0" and local.get("workout_days", "0") != "0" else "partial",
            "sleep_days": local.get("sleep_days", "0"),
            "sleep_state": local.get("sleep_state", "learning"),
            "sleep_ready": local.get("sleep_ready", "0"),
            "sleep_blocker": local.get("sleep_blocker", "sleep_low_confidence"),
            "workout_days": local.get("workout_days", "0"),
            "workout_state": local.get("workout_state", "learning"),
            "workout_saved_ready": local.get("saved_workout_ready", "0"),
            "workout_near_miss": local.get("saved_workout_near_miss", "0"),
            "workout_near_miss_reason": local.get("saved_workout_near_miss_reason", "none"),
            "workout_best_source": local.get("saved_workout_source", "missing"),
            "workout_best_blocker": local.get("saved_workout_blocker", "missing"),
            "workout_best_stream_coverage_percent": local.get("saved_workout_stream_coverage_percent", "0"),
            "workout_best_threshold_gap_bpm": local.get("saved_workout_threshold_gap_bpm", "0"),
            "historical_gap_repair_status": local.get("historical_gap_repair_status", "missing"),
            "historical_gap_repair_reason": local.get("historical_gap_repair_reason", "missing"),
            "motion_validated": local.get("motion_validated", "0"),
            "watchdog_no_data_recoveries": local.get("watchdog_no_data_recoveries", "0"),
            "watchdog_hr_continuity_recoveries": local.get("watchdog_hr_continuity_recoveries", "0"),
            "watchdog_accepted_hr_recoveries": local.get("watchdog_accepted_hr_recoveries", "0"),
            "watchdog_last_source": local.get("watchdog_last_source", "missing"),
            "watchdog_last_action": local.get("watchdog_last_action", "missing"),
        },
        "F": {
            "status": trend90.get("confidence", local.get("trend_state", "learning")),
            "trend90_coverage_days": trend90.get("coverage_days", "0"),
            "trend90_coverage_percent": trend90.get("coverage_percent", local.get("trend90_coverage_percent", "0")),
            "hrv_reference_gated": "1",
        },
        "G": {
            "status": "metric_gated" if healthkit_export_verify.get("status") == "ok" else "partial",
            "backup_available": "1" if backup else "0",
            "backup_current": backup.get("digest_match", "0"),
            "healthkit_entitlement": "present" if healthkit_export else "missing",
            "healthkit_available": "1" if healthkit_export_verify else "missing",
            "healthkit_hr_samples": healthkit_export_verify.get(
                "readback_atria_hr_samples",
                healthkit_export.get("hr_samples", backup.get("current_hr_accepted", "0")),
            ),
            "healthkit_workouts": healthkit_export.get("workouts", "missing"),
            "healthkit_hrv_samples": healthkit_export.get("hrv_samples", "0"),
            "healthkit_readback_status": healthkit_export_verify.get("status", "missing"),
            "healthkit_readback_data_appears": healthkit_export_verify.get("data_appears", "0"),
            "healthkit_readback_reconciliation": healthkit_export_verify.get("reconciliation", "missing"),
            "healthkit_external_reference_ready": healthkit_reference.get("external_reference_ready", "0"),
            "metric_blockers": "healthkit_hrv_reference_pending+healthkit_workout_learning",
            "widget_storage": widget.get("storage", "missing"),
            "widget_app_group": widget.get("app_group", "0"),
            "widget_target": widget_target,
            "complication_target": complication_target,
        },
        "H": {
            "status": "ready" if historical_raw_ready == "1" else "partial",
            "historical_download_validated": historical_raw_ready,
            "gate_h_protocol_exit_ready": historical_raw_ready,
            "historical_archive_local": historical_raw_ready,
            "historical_archive_parse_ok": historical_raw_ready,
            "historical_archive_rows": historical_rows,
            "historical_archive_raw_payload_rows": historical_rows,
            "historical_archive_undecodable_rows": "0" if historical_raw_ready == "1" else "missing",
            "historical_archive_metric_usable": local.get("historical_archive_metric_usable", "0"),
            "historical_archive_current_usable": local.get("historical_archive_current_usable", "0"),
            "historical_archive_gravity_rows": local.get("historical_archive_gravity_rows", "0"),
            "historical_archive_gravity_validated_rows": local.get("historical_archive_gravity_validated_rows", "0"),
            "historical_rr_metric_ready": "0",
            "new_sensor_validated": "0",
        },
    }
    return summary, gates


def val(row: dict[str, str], key: str, default: str = "missing") -> str:
    return row.get(key, default)


def int_val(row: dict[str, str], key: str, default: int = 0) -> int:
    raw = val(row, key, str(default))
    return int_or_zero(raw, default=default)


def int_or_zero(raw: str | None, default: int = 0) -> int:
    if raw is None:
        return default
    try:
        return int(float(raw))
    except ValueError:
        return default


def code_value(raw: str, default: str = "missing") -> str:
    cleaned = (raw or default).strip()
    return cleaned.replace(" ", "_") or default


def is_bounded_large_store(row: dict[str, str]) -> bool:
    return val(row, "bounded_large_store", "0") == "1"


def is_skipped_bounded(row: dict[str, str], key: str) -> bool:
    return code_value(val(row, key, "")) == "skipped_bounded_audit"


def gate_h_protocol_ready(row: dict[str, str]) -> bool:
    if val(row, "gate_h_protocol_exit_ready", val(row, "historical_download_validated", "0")) == "1":
        return True
    return (
        val(row, "historical_archive_local", "0") == "1"
        and val(row, "historical_archive_parse_ok", "0") == "1"
        and val(row, "stored_transfer_verified", "0") == "1"
        and int_val(row, "codec_ok_frames") > 0
        and int_val(row, "codec_bad_frames") == 0
        and int_val(row, "historical_archive_rows") > 0
        and int_val(row, "historical_archive_raw_payload_rows") > 0
        and int_val(row, "historical_archive_undecodable_rows") == 0
    )


def gate_e_sleep_blocker(row: dict[str, str]) -> str:
    if val(row, "focused_validation", "0") == "1" and val(row, "sleep_validation_checked", "1") != "1":
        return "sleep_not_checked_focused_validation"
    if is_bounded_large_store(row) and is_skipped_bounded(row, "sleep_replay"):
        return "sleep_replay_skipped_bounded_audit"
    if val(row, "sleep_days", "0") == "0":
        return "sleep_capture_missing"
    if val(row, "sleep_ready", "0") != "1":
        fallback = "sleep_motion_unvalidated" if val(row, "motion_validated", "0") != "1" else val(row, "sleep_state", "sleep_not_ready")
        return code_value(val(row, "sleep_blocker", fallback))
    if val(row, "motion_validated", "0") != "1":
        return code_value(val(row, "sleep_blocker", "sleep_motion_unvalidated"))
    return "none"


def gate_e_workout_blocker(row: dict[str, str]) -> str:
    if val(row, "focused_validation", "0") == "1" and val(row, "workout_validation_checked", "1") != "1":
        return "workout_not_checked_focused_validation"
    if is_bounded_large_store(row) and is_skipped_bounded(row, "workout_replay"):
        return "workout_replay_skipped_bounded_audit"
    if val(row, "workout_saved_ready", "0") == "1" or val(row, "workout_days", "0") != "0":
        return "none"
    blocker_value = code_value(val(row, "workout_best_blocker", val(row, "workout_state", "workout_capture_missing")))
    if val(row, "workout_near_miss", "0") == "1":
        reason = code_value(val(row, "workout_near_miss_reason", "near_miss"))
        return f"near_miss:{blocker_value}:{reason}"
    return blocker_value


def next_action(gate: str, row: dict[str, str]) -> str:
    status = row.get("status", "missing")
    if gate == "local":
        return "Use this row as the current-store dashboard; it is not a gate exit."
    if gate == "A":
        return "For each launch, confirm live BLE/RR in ATRIADBG; Gate A implementation is otherwise done."
    if gate == "B":
        if val(row, "reference_validated", "0") != "1":
            if val(row, "saved_rr_ready", "0") == "1":
                action = code_value(val(row, "reference_action", "provide_independent_rr_ibi_recording"))
                rmssd = val(row, "saved_rr_best_rmssd", "missing")
                conf = val(row, "saved_rr_confidence", "missing")
                return f"WHOOP-side 300s RR package is ready (rmssd={rmssd} ms, conf={conf}%); finish Gate B by providing an independent RR/IBI reference and rerunning validation: {action}."
            return "Compare a ready saved/live RR package against an external RR/IBI reference within +/-5 ms RMSSD."
        return "Keep HRV surfaces confidence-gated and preserve reference evidence."
    if gate == "C":
        baseline = val(row, "validated_hrv_baseline", "0/7")
        return f"Collect reference-validated morning HRV until baseline reaches {baseline} -> 7/7."
    if gate == "D":
        if val(row, "reference_validated", "0") != "1":
            if val(row, "saved_hr_ready", "0") == "1":
                action = code_value(val(row, "reference_action", "provide_independent_chest_strap_hr_recording"))
                samples = val(row, "strap_samples", "missing")
                avg_hr = val(row, "whoop_avg_hr", "missing")
                peak_hr = val(row, "whoop_peak_hr", "missing")
                reason = code_value(val(row, "reference_validation_reason", val(row, "primary_blocker", "external_hr_reference_missing")))
                return f"WHOOP-side HR package is ready (samples={samples}, avg={avg_hr} bpm, peak={peak_hr} bpm); finish Gate D with an independent HR CSV/reference within +/-2 bpm: {action}. Current reference blocker is {reason}."
        strain_blocker = val(row, "primary_blocker", "external_hr_rest_to_max_validation")
        return f"Run external chest-strap HR check plus real rest-to-max validation; current blocker is {strain_blocker}."
    if gate == "E":
        if is_bounded_large_store(row) and (
            is_skipped_bounded(row, "sleep_replay")
            or is_skipped_bounded(row, "workout_replay")
        ):
            return "Bounded fast audit skipped Gate E replay; run targeted --log-daily-rollups/--verify-sleep or Gate E workout diagnostics before judging sleep/workout readiness."
        sleep_blocker = gate_e_sleep_blocker(row)
        workout_blocker = gate_e_workout_blocker(row)
        recovery_count = (
            int_val(row, "watchdog_no_data_recoveries")
            + int_val(row, "watchdog_hr_continuity_recoveries")
            + int_val(row, "watchdog_accepted_hr_recoveries")
        )
        recovery_detail = ""
        if recovery_count:
            recovery_detail = (
                f" Watchdog recovery observed ({recovery_count}; "
                f"last={code_value(val(row, 'watchdog_last_source', 'missing'))}/"
                f"{code_value(val(row, 'watchdog_last_action', 'missing'))})."
            )
        if sleep_blocker == "sleep_motion_unvalidated_historical_stale":
            sleep_detail = "sleep blocker sleep_motion_unvalidated_historical_stale (current sleep needs current-history selector or validated current IMU; stale gravity stays diagnostic-only)"
        else:
            sleep_detail = f"sleep blocker {sleep_blocker}"
        if val(row, "sleep_fallback_available", "0") == "1":
            fallback_source = code_value(val(row, "sleep_fallback_source", "hr_only_sleep"))
            fallback_duration = int_val(row, "sleep_fallback_duration_s")
            fallback_chunks = int_val(row, "sleep_fallback_chunks")
            sleep_detail += (
                f"; HR-only fallback observed source={fallback_source} "
                f"duration_s={fallback_duration} chunks={fallback_chunks} diagnostic_only=1"
            )
        if sleep_blocker != "none" and workout_blocker != "none":
            return f"Gate E remains partial: {sleep_detail}; workout blocker {workout_blocker}.{recovery_detail}"
        if sleep_blocker != "none":
            return f"Gate E remains partial: {sleep_detail}; keep sleep learning until validated motion/IMU evidence or labeled fallback is ready.{recovery_detail}"
        if workout_blocker != "none":
            return f"Gate E remains partial: workout blocker {workout_blocker}; need a real sustained elevated-HR workout capture.{recovery_detail}"
        return "Verify sleep plus workout rollups stay ready on current store."
    if gate == "F":
        if is_bounded_large_store(row) and is_skipped_bounded(row, "trend_replay"):
            return "Bounded fast audit skipped trend replay; run --log-trends for 7/30/90-day coverage and anomaly blockers."
        return "Accumulate real 7/30/90-day local history; keep sparse/HRV-reference-gated trends labeled learning."
    if gate == "G":
        if status == "metric_gated":
            metric_blockers = code_value(val(row, "metric_blockers", "healthkit_hrv_reference_pending+healthkit_workout_learning"))
            if "healthkit_status_skipped_bounded_audit" in metric_blockers:
                return f"Bounded fast audit skipped HealthKit readback; run dedicated Gate G HealthKit diagnostics. Upstream metric blockers still apply: {metric_blockers}."
            return f"Gate G platform is verified; wait on upstream metric blockers before exporting HRV/workouts: {metric_blockers}."
        missing = blocker(gate, row)
        if missing != "platform_verification":
            return f"Finish Gate G blockers: {missing}; then verify Apple Health writes, widget/app-group rendering, complication, notifications, and backup on device."
        return "Verify production notifications, HealthKit writes, widget, and backup together."
    if gate == "H":
        if is_bounded_large_store(row) and is_skipped_bounded(row, "historical_archive"):
            return "Bounded fast audit skipped historical archive replay; skip blind historical selector retries unless new selector/sniffer evidence or a new sensor decode path appears."
        if val(row, "historical_archive_local", "0") != "1":
            return "Run a historical transfer and pull the on-device archive before trying stored-session metrics."
        if val(row, "historical_archive_parse_ok", "0") != "1":
            return "Fix the local historical JSONL archive before ACKing or interpreting more stored data."
        if gate_h_protocol_ready(row):
            rows = val(row, "historical_archive_rows", "0")
            current = val(row, "historical_archive_current_usable", "0")
            return f"Gate H protocol exit is satisfied by codec-clean historical download ({rows} rows); metrics remain fail-closed until current-session usable={current} and external validation pass."
        if val(row, "historical_rr_metric_ready", "0") != "1":
            rows = val(row, "historical_archive_rows", "0")
            current = val(row, "historical_archive_current_usable", "0")
            return f"Archive is present ({rows} rows, current_usable={current}) but remains fail-closed until current-session selection and external validation exist."
        if val(row, "new_sensor_validated", "0") != "1":
            return "Decode and validate at least one new sensor stream, or document hardware/protocol limit."
        return "Preserve codec-clean historical/new-sensor evidence."
    if status == "missing":
        return "No current device evidence found for this gate."
    return "Review evidence manually."


def blocker(gate: str, row: dict[str, str]) -> str:
    if not row:
        return "missing_evidence"
    if gate == "B":
        return "external_rr_reference" if val(row, "reference_validated", "0") != "1" else "none"
    if gate == "C":
        return f"validated_hrv_baseline_{val(row, 'validated_hrv_baseline', '0/7')}"
    if gate == "D":
        return code_value(val(row, "primary_blocker", "external_hr_rest_to_max_validation"))
    if gate == "E":
        if is_bounded_large_store(row) and (
            is_skipped_bounded(row, "sleep_replay")
            or is_skipped_bounded(row, "workout_replay")
        ):
            blockers = []
            if is_skipped_bounded(row, "sleep_replay"):
                blockers.append("sleep_replay_skipped_bounded_audit")
            if is_skipped_bounded(row, "workout_replay"):
                blockers.append("workout_replay_skipped_bounded_audit")
            return ",".join(blockers)
        blockers = [item for item in [gate_e_sleep_blocker(row), gate_e_workout_blocker(row)] if item != "none"]
        return ",".join(blockers) or "none"
    if gate == "F":
        if is_bounded_large_store(row) and is_skipped_bounded(row, "trend_replay"):
            return "trend_replay_skipped_bounded_audit"
        explicit = val(row, "trend_blockers", "")
        if explicit:
            return explicit
        return f"coverage_{val(row, 'trend90_coverage_percent', '0')}pct_hrv_gated_{val(row, 'hrv_reference_gated', '1')}"
    if gate == "G":
        if row.get("status") == "metric_gated":
            return code_value(val(row, "metric_blockers", "healthkit_hrv_reference_pending+healthkit_workout_learning"))
        missing = []
        if val(row, "healthkit_entitlement", "") == "missing":
            missing.append("healthkit_entitlement")
        if val(row, "widget_target", "0") == "0":
            missing.append("widget_target")
        if val(row, "widget_app_group", "0") == "0":
            missing.append("app_group")
        if val(row, "complication_target", "0") == "0":
            missing.append("complication_target")
        return ",".join(missing) or "platform_verification"
    if gate == "H":
        if is_bounded_large_store(row) and is_skipped_bounded(row, "historical_archive"):
            return "historical_archive_skipped_bounded_audit"
        missing = []
        if val(row, "historical_archive_local", "0") != "1":
            missing.append("historical_archive_local")
        if val(row, "historical_archive_parse_ok", "0") != "1":
            missing.append("historical_archive_parse")
        protocol_ready = gate_h_protocol_ready(row)
        if not protocol_ready:
            missing.append("gate_h_protocol_exit_ready")
        if protocol_ready and val(row, "historical_rr_metric_ready", "0") != "1":
            missing.append("metric_fail_closed")
        elif val(row, "historical_rr_metric_ready", "0") != "1":
            missing.append("historical_rr_metric_ready")
        if not protocol_ready and val(row, "new_sensor_validated", "0") != "1":
            missing.append("new_sensor_validated")
        return ",".join(missing) or "none"
    return row.get("status", "unknown")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--strict", action="store_true", help="Exit nonzero if any gate row is missing.")
    args = parser.parse_args()

    summary, gates = load_status(args.log)
    print(f"log={args.log}")
    if summary:
        print(
            "summary "
            f"sessions={val(summary, 'sessions')} days={val(summary, 'days')} "
            f"rest_hr={val(summary, 'rest_hr')} max_hr={val(summary, 'max_hr')} "
            f"backup_current={val(summary, 'backup_current')} "
            f"healthkit_entitlement={val(summary, 'healthkit_entitlement')} "
            f"healthkit_hr_samples={val(summary, 'healthkit_hr_samples')} "
            f"healthkit_workouts={val(summary, 'healthkit_workouts')}"
        )
    else:
        print("summary missing")

    print("gate\tstatus\tblocker\tnext_action")
    missing = []
    for gate in GATE_ORDER:
        row = gates.get(gate, {})
        if not row:
            missing.append(gate)
        print("\t".join([gate, row.get("status", "missing"), blocker(gate, row), next_action(gate, row)]))
    if missing:
        print(f"missing_gates={','.join(missing)}")
    return 1 if args.strict and missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
