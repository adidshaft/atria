#!/usr/bin/env python3
"""Summarize Gate E workout evidence from a Atria ATRIADBG log.

The live-device logs are intentionally verbose. This tool reduces them to a
single honest decision: did the workout detector have enough real saved/live HR
evidence to pass, and if not, what blocker was actually observed?
"""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


KEY_RE = re.compile(r"(?<![A-Za-z0-9_])_?([A-Za-z][A-Za-z0-9_]*)=")


def kv_after(marker: str, line: str) -> dict[str, str]:
    if marker not in line:
        return {}
    tail = line.split(marker, 1)[1].strip()
    matches = list(KEY_RE.finditer(tail))
    parsed: dict[str, str] = {}
    for index, match in enumerate(matches):
        key = match.group(1)
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(tail)
        value = tail[start:end].strip().rstrip(";")
        parsed[key] = value
    return parsed


def matches_label(value: str | None, requested: str) -> bool:
    if not requested:
        return True
    if value is None:
        return False
    return value == requested or value.startswith(f"{requested} ")


def as_int(value: str | None, default: int = 0) -> int:
    if value is None:
        return default
    try:
        return int(float(value))
    except ValueError:
        return default


def as_float(value: str | None, default: float = 0.0) -> float:
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


def compact_value(value: str | None) -> str:
    if value is None or value == "":
        return "missing"
    return value.replace(" ", "_")


def first_value(row: dict[str, str], *keys: str) -> str | None:
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return value
    return None


@dataclass
class LogEvidence:
    build_succeeded: bool = False
    app_installed: bool = False
    app_launched: bool = False
    preflight: dict[str, str] | None = None
    checkpoint_schedule: dict[str, str] | None = None
    checkpoint_saved: dict[str, str] | None = None
    hr_continuity_schedule: dict[str, str] | None = None
    hr_continuity_actions: int = 0
    last_hr_continuity: dict[str, str] | None = None
    live_schedule: dict[str, str] | None = None
    live_ticks: int = 0
    last_live: dict[str, str] | None = None
    best_live: dict[str, str] | None = None
    auto_save_schedule: dict[str, str] | None = None
    auto_save_saved: dict[str, str] | None = None
    auto_save_learning: dict[str, str] | None = None
    validation: dict[str, str] | None = None
    replay: dict[str, str] | None = None
    gate_e: dict[str, str] | None = None
    backup: dict[str, str] | None = None
    backup_verify: dict[str, str] | None = None
    daily_rollup: dict[str, str] | None = None
    local_status: dict[str, str] | None = None
    summary: dict[str, str] = field(default_factory=dict)

    def ingest(self, line: str, label: str) -> None:
        if "BUILD SUCCEEDED" in line:
            self.build_succeeded = True
        if "installed app" in line.lower() or "installationURL" in line:
            self.app_installed = True
        if "Launching application" in line or "devicectl device process launch" in line:
            self.app_launched = True

        if "ATRIADBG workout_preflight" in line:
            self.preflight = kv_after("ATRIADBG workout_preflight", line)
        elif "ATRIADBG session_checkpoint schedule" in line:
            tokens = kv_after("ATRIADBG session_checkpoint schedule", line)
            if matches_label(tokens.get("label"), label):
                self.checkpoint_schedule = tokens
        elif "ATRIADBG session_checkpoint status=saved" in line:
            tokens = kv_after("ATRIADBG session_checkpoint", line)
            if matches_label(tokens.get("label"), label):
                self.checkpoint_saved = tokens
        elif "ATRIADBG hr_continuity_watchdog schedule" in line:
            tokens = kv_after("ATRIADBG hr_continuity_watchdog schedule", line)
            if matches_label(tokens.get("label"), label):
                self.hr_continuity_schedule = tokens
        elif "ATRIADBG hr_continuity_watchdog status=" in line or (
            "ATRIADBG hr_continuity_watchdog persisted=1" in line
        ):
            tokens = kv_after("ATRIADBG hr_continuity_watchdog", line)
            if matches_label(tokens.get("label"), label):
                self.hr_continuity_actions += 1
                self.last_hr_continuity = tokens
        elif "ATRIADBG live_workout schedule" in line:
            tokens = kv_after("ATRIADBG live_workout schedule", line)
            if matches_label(tokens.get("label"), label):
                self.live_schedule = tokens
        elif "ATRIADBG live_workout tick=" in line:
            tokens = kv_after("ATRIADBG live_workout", line)
            if matches_label(tokens.get("label"), label):
                self.live_ticks += 1
                self.last_live = tokens
                if better_workout_row(tokens, self.best_live):
                    self.best_live = tokens
        elif "ATRIADBG workout_auto_save schedule" in line:
            tokens = kv_after("ATRIADBG workout_auto_save schedule", line)
            if matches_label(tokens.get("label"), label):
                self.auto_save_schedule = tokens
        elif "ATRIADBG workout_auto_save status=saved" in line:
            tokens = kv_after("ATRIADBG workout_auto_save", line)
            if matches_label(tokens.get("label"), label):
                self.auto_save_saved = tokens
        elif "ATRIADBG workout_auto_save status=learning" in line:
            tokens = kv_after("ATRIADBG workout_auto_save", line)
            if matches_label(tokens.get("label"), label):
                self.auto_save_learning = tokens
        elif "ATRIADBG workout_validation" in line:
            tokens = kv_after("ATRIADBG workout_validation", line)
            if "status" in tokens and matches_label(tokens.get("label"), label):
                self.validation = tokens
        elif "ATRIADBG workout_replay_summary" in line:
            self.replay = kv_after("ATRIADBG workout_replay_summary", line)
        elif "ATRIADBG gate_status gate=E" in line:
            self.gate_e = kv_after("ATRIADBG gate_status", line)
        elif "ATRIADBG session_backup " in line:
            self.backup = kv_after("ATRIADBG session_backup", line)
        elif "ATRIADBG session_backup_verify " in line:
            self.backup_verify = kv_after("ATRIADBG session_backup_verify", line)
        elif "ATRIADBG daily_rollup" in line:
            self.daily_rollup = kv_after("ATRIADBG daily_rollup", line)
        elif "ATRIADBG local_status" in line:
            self.local_status = kv_after("ATRIADBG local_status", line)
        elif "=" in line and line.startswith(("ATRIADBG_", "notify_", "rr_", "standard_", "frame_", "hrv_", "realtime_")):
            key, value = line.strip().split("=", 1)
            self.summary[key] = value

    def ready(self) -> bool:
        if self.auto_save_saved is not None:
            return True
        if (self.validation or {}).get("status") == "ready":
            return True
        if as_int((self.gate_e or {}).get("workout_saved_ready")) > 0:
            return True
        return False

    def status(self) -> str:
        if self.ready():
            return "ready"
        if self.validation is not None:
            return compact_value(self.validation.get("status"))
        if self.auto_save_learning is not None or self.last_live is not None:
            return "learning"
        if self.local_status is not None:
            return "local_status"
        return "missing_workout_evidence"

    def blocker_row(self) -> dict[str, str] | None:
        for row in (self.validation, self.auto_save_learning, self.best_live, self.replay, self.local_status):
            if row is self.validation and not has_workout_metrics(row):
                continue
            if row is not None:
                return row
        return None

    def missing(self) -> list[str]:
        missing: list[str] = []
        if self.preflight is None:
            missing.append("workout_preflight")
        elif self.preflight.get("threshold_method") != "hrr50":
            missing.append("hrr50_preflight")
        if self.checkpoint_schedule is None:
            missing.append("checkpoint_schedule")
        if self.checkpoint_saved is None:
            missing.append("checkpoint_saved")
        if self.live_schedule is None:
            missing.append("live_workout_schedule")
        if self.live_ticks == 0:
            missing.append("live_workout_ticks")
        if self.auto_save_schedule is None:
            missing.append("workout_auto_save_schedule")
        if self.validation is None:
            missing.append("workout_validation")
        if self.gate_e is None:
            missing.append("gate_e_status")
        if self.backup_verify is None:
            missing.append("backup_verify")
        elif self.backup_verify.get("status") != "ok" or self.backup_verify.get("digest_match") != "1":
            missing.append("backup_digest_match")
        return missing


def better_workout_row(candidate: dict[str, str], current: dict[str, str] | None) -> bool:
    if current is None:
        return True
    candidate_tuple = (
        as_int(candidate.get("ready")),
        as_float(candidate.get("observed_duration_s")),
        as_float(candidate.get("elevated_s")),
        as_float(candidate.get("longest_bout_s")),
        as_int(candidate.get("peak_hr")),
        -as_float(candidate.get("max_gap_s")),
    )
    current_tuple = (
        as_int(current.get("ready")),
        as_float(current.get("observed_duration_s")),
        as_float(current.get("elevated_s")),
        as_float(current.get("longest_bout_s")),
        as_int(current.get("peak_hr")),
        -as_float(current.get("max_gap_s")),
    )
    return candidate_tuple > current_tuple


def has_workout_metrics(row: dict[str, str] | None) -> bool:
    if row is None:
        return False
    return any(
        row.get(key)
        for key in (
            "primary_blocker",
            "stream_coverage_percent",
            "observed_duration_s",
            "live_workout_stream_coverage_percent",
            "live_workout_observed_duration_s",
        )
    )


def analyze(path: Path, label: str) -> LogEvidence:
    evidence = LogEvidence()
    for line in path.read_text(errors="replace").splitlines():
        evidence.ingest(line, label)
    return evidence


def print_report(evidence: LogEvidence, label: str, path: Path) -> None:
    blocker = evidence.blocker_row() or {}
    preflight = evidence.preflight or {}
    gate = evidence.gate_e or {}
    backup = evidence.backup_verify or {}
    replay = evidence.replay or {}
    best_live = evidence.best_live or {}
    repair = gate if gate.get("historical_gap_repair_status") else (evidence.local_status or {})
    missing = evidence.missing()

    fields: list[tuple[str, str | int | float]] = [
        ("gate_e_workout_ready", 1 if evidence.ready() else 0),
        ("status", evidence.status()),
        ("label", label or "any"),
        ("log", str(path)),
        ("build_succeeded", 1 if evidence.build_succeeded else 0),
        ("preflight_ok", 1 if preflight.get("threshold_method") == "hrr50" else 0),
        ("rest_hr", compact_value(preflight.get("rest_hr") or blocker.get("rest_hr"))),
        ("max_hr", compact_value(preflight.get("max_hr") or blocker.get("max_hr"))),
        ("threshold_hr", compact_value(preflight.get("threshold_hr") or blocker.get("threshold_hr"))),
        ("threshold_method", compact_value(preflight.get("threshold_method"))),
        ("checkpoint_saved", 1 if evidence.checkpoint_saved is not None else 0),
        ("hr_continuity_watchdog_scheduled", 1 if evidence.hr_continuity_schedule is not None else 0),
        ("hr_continuity_watchdog_actions", evidence.hr_continuity_actions),
        ("hr_continuity_last_status", compact_value((evidence.last_hr_continuity or {}).get("status"))),
        ("hr_continuity_last_action", compact_value((evidence.last_hr_continuity or {}).get("action"))),
        ("hr_continuity_last_raw_gap_s", compact_value((evidence.last_hr_continuity or {}).get("raw_gap_s"))),
        ("hr_continuity_last_accepted_gap_s", compact_value((evidence.last_hr_continuity or {}).get("accepted_gap_s"))),
        ("live_ticks", evidence.live_ticks),
        ("auto_save_saved", 1 if evidence.auto_save_saved is not None else 0),
        ("validation_status", compact_value((evidence.validation or {}).get("status"))),
        ("validation_reason", compact_value((evidence.validation or {}).get("reason"))),
        ("primary_blocker", compact_value(first_value(blocker, "primary_blocker", "saved_workout_blocker", "live_workout_blocker"))),
        ("capture_diagnosis", compact_value(first_value(blocker, "capture_diagnosis", "saved_workout_capture_diagnosis"))),
        ("capture_action", compact_value(first_value(blocker, "capture_action", "saved_workout_capture_action"))),
        ("stream_coverage_percent", compact_value(first_value(blocker, "stream_coverage_percent", "saved_workout_stream_coverage_percent", "live_workout_stream_coverage_percent"))),
        ("duration_s", compact_value(first_value(blocker, "duration_s", "saved_workout_duration_s", "live_workout_duration_s"))),
        ("observed_duration_s", compact_value(first_value(blocker, "observed_duration_s", "saved_workout_observed_s", "live_workout_observed_duration_s"))),
        ("dropped_gap_s", compact_value(first_value(blocker, "dropped_gap_s", "saved_workout_dropped_gap_s", "live_workout_dropped_gap_s"))),
        ("max_gap_s", compact_value(first_value(blocker, "max_gap_s", "saved_workout_max_gap_s", "live_workout_max_gap_s"))),
        ("gap_count", compact_value(first_value(blocker, "gap_count", "saved_workout_gap_count", "live_workout_gap_count"))),
        ("samples", compact_value(first_value(blocker, "samples", "live_workout_samples"))),
        ("avg_hr", compact_value(first_value(blocker, "avg_hr", "live_workout_avg_hr"))),
        ("peak_hr", compact_value(first_value(blocker, "peak_hr", "saved_workout_peak_hr", "live_workout_peak_hr"))),
        ("threshold_gap_bpm", compact_value(first_value(blocker, "threshold_gap_bpm", "saved_workout_threshold_gap_bpm") or gate.get("workout_best_threshold_gap_bpm"))),
        ("elevated_s", compact_value(first_value(blocker, "elevated_s", "saved_workout_elevated_s", "live_workout_elevated_s"))),
        ("required_elevated_s", compact_value(first_value(blocker, "required_elevated_s", "saved_workout_required_elevated_s", "live_workout_required_elevated_s"))),
        ("longest_bout_s", compact_value(first_value(blocker, "longest_bout_s", "saved_workout_longest_bout_s", "live_workout_longest_bout_s"))),
        ("required_bout_s", compact_value(first_value(blocker, "required_bout_s", "saved_workout_required_bout_s", "live_workout_required_bout_s"))),
        ("borderline_threshold_hr", compact_value(first_value(blocker, "borderline_threshold_hr", "saved_workout_borderline_threshold_hr") or gate.get("workout_best_borderline_threshold_hr"))),
        ("borderline_elevated_s", compact_value(first_value(blocker, "borderline_elevated_s", "saved_workout_borderline_elevated_s") or gate.get("workout_best_borderline_elevated_s"))),
        ("borderline_longest_bout_s", compact_value(first_value(blocker, "borderline_longest_bout_s", "saved_workout_borderline_longest_bout_s") or gate.get("workout_best_borderline_longest_bout_s"))),
        ("borderline_diagnostic_only", compact_value(first_value(blocker, "borderline_diagnostic_only", "saved_workout_borderline_diagnostic_only") or gate.get("workout_borderline_diagnostic_only"))),
        ("hr_raw_2a37", compact_value(first_value(blocker, "hr_raw_2a37"))),
        ("hr_accepted", compact_value(first_value(blocker, "hr_accepted"))),
        ("hr_zero", compact_value(first_value(blocker, "hr_zero"))),
        ("hr_artifact_held", compact_value(first_value(blocker, "hr_artifact_held"))),
        ("hr_artifact_dropped", compact_value(first_value(blocker, "hr_artifact_dropped"))),
        ("hr_raw_gaps", compact_value(first_value(blocker, "hr_raw_gaps"))),
        ("hr_accepted_gaps", compact_value(first_value(blocker, "hr_accepted_gaps"))),
        ("hr_max_raw_gap_s", compact_value(first_value(blocker, "hr_max_raw_gap_s"))),
        ("hr_max_accepted_gap_s", compact_value(first_value(blocker, "hr_max_accepted_gap_s"))),
        ("hr_sample_last_status", compact_value(first_value(blocker, "hr_sample_last_status"))),
        ("hr_sample_last_reason", compact_value(first_value(blocker, "hr_sample_last_reason"))),
        ("historical_gap_repair_status", compact_value(repair.get("historical_gap_repair_status"))),
        ("historical_gap_repair_reason", compact_value(repair.get("historical_gap_repair_reason"))),
        ("historical_gap_repair_overlap_s", compact_value(repair.get("historical_gap_repair_overlap_s"))),
        ("historical_gap_repair_separation_s", compact_value(repair.get("historical_gap_repair_separation_s"))),
        ("historical_gap_repair_current_usable_rows", compact_value(repair.get("historical_gap_repair_current_usable_rows"))),
        ("historical_gap_repair_metric_usable", compact_value(repair.get("historical_gap_repair_metric_usable"))),
        ("historical_gap_repair_diagnostic_only", compact_value(repair.get("historical_gap_repair_diagnostic_only"))),
        ("active_journal_rr_values", compact_value((evidence.local_status or {}).get("active_journal_rr_values"))),
        ("active_journal_rr_max_gap_s", compact_value((evidence.local_status or {}).get("active_journal_rr_max_gap_s"))),
        ("active_journal_rr_gap_over_3s", compact_value((evidence.local_status or {}).get("active_journal_rr_gap_over_3s"))),
        ("active_journal_rr_gap_over_5s", compact_value((evidence.local_status or {}).get("active_journal_rr_gap_over_5s"))),
        ("active_journal_rr_coverage_3s_percent", compact_value((evidence.local_status or {}).get("active_journal_rr_coverage_3s_percent"))),
        ("best_live_peak_hr", compact_value(best_live.get("peak_hr"))),
        ("best_live_observed_s", compact_value(best_live.get("observed_duration_s"))),
        ("gate_e_status", compact_value(gate.get("status"))),
        ("workout_days", compact_value(gate.get("workout_days"))),
        ("workout_saved_ready", compact_value(gate.get("workout_saved_ready"))),
        ("workout_best_reason", compact_value(gate.get("workout_best_reason"))),
        ("workout_best_blocker", compact_value(gate.get("workout_best_blocker"))),
        ("replay_ready", compact_value(replay.get("ready"))),
        ("replay_reason", compact_value(replay.get("reason"))),
        ("backup_verified", 1 if backup.get("status") == "ok" and backup.get("digest_match") == "1" else 0),
        ("backup_sessions", compact_value(backup.get("sessions") or (evidence.backup or {}).get("sessions"))),
        ("missing", ",".join(missing) if missing else "none"),
    ]

    for key, value in fields:
        print(f"{key}={value}")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--label", default="gate-e-hrr50-workout")
    args = parser.parse_args(argv)

    if not args.log.is_file():
        raise SystemExit(f"missing log: {args.log}")
    evidence = analyze(args.log, args.label)
    print_report(evidence, args.label, args.log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
