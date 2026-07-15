#!/usr/bin/env python3
"""Pure, fail-closed step-calibration preflight summaries.

The pull script owns archive I/O.  Keeping the arithmetic and preference-state
validation here makes the forecast deterministic and independently testable.
"""

from __future__ import annotations

import ast
import json
import math
import re
from typing import Iterable


REQUIRED_DELAY_HOURS = 2.0
SAFETY_MARGIN = 1.25
RECENT_WINDOW_HOURS = 6.0
MINIMUM_EVIDENCE_HOURS = 1.0
MINIMUM_EVIDENCE_ROWS = 60

_STAGES = (
    ("Rest before", "rest", 0, 60_000),
    ("Slow 100", "walk", 100, 2_000),
    ("Normal 100", "walk", 100, 2_000),
    ("Brisk 100", "walk", 100, 2_000),
    ("Normal 200", "walk", 200, 2_000),
    ("Rest after", "rest", 0, 60_000),
)


def _safe_positive_int(expression: str) -> int | None:
    """Evaluate the small integer-only expressions used by the Swift defaults."""
    try:
        root = ast.parse(expression.strip(), mode="eval")
    except (SyntaxError, ValueError):
        return None

    def evaluate(node: ast.AST) -> int:
        if isinstance(node, ast.Expression):
            return evaluate(node.body)
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Mult, ast.Add, ast.Sub, ast.FloorDiv)):
            left = evaluate(node.left)
            right = evaluate(node.right)
            if isinstance(node.op, ast.Mult):
                return left * right
            if isinstance(node.op, ast.Add):
                return left + right
            if isinstance(node.op, ast.Sub):
                return left - right
            if right == 0:
                raise ValueError("division by zero")
            return left // right
        raise ValueError("unsupported expression")

    try:
        value = evaluate(root)
    except (TypeError, ValueError, OverflowError):
        return None
    return value if value > 0 else None


def discover_capacity(source: str) -> tuple[int | None, int | None]:
    """Read the production default cap and maximum segment from Swift source."""
    cap_match = re.search(
        r"maximumArchiveBytes:\s*Int64\s*=\s*([^,\n]+)", source
    )
    file_match = re.search(
        r"maximumFileBytes\s*=\s*max\(\s*([^,]+),\s*min\(\s*([^,]+),"
        r"\s*self\.maximumArchiveBytes\s*/\s*([0-9_]+)\s*\)\s*\)",
        source,
        re.DOTALL,
    )
    if cap_match is None or file_match is None:
        return None, None
    capacity = _safe_positive_int(cap_match.group(1))
    minimum_file = _safe_positive_int(file_match.group(1))
    maximum_file_literal = _safe_positive_int(file_match.group(2))
    divisor = _safe_positive_int(file_match.group(3))
    if None in (capacity, minimum_file, maximum_file_literal, divisor):
        return None, None
    assert capacity is not None
    assert minimum_file is not None
    assert maximum_file_literal is not None
    assert divisor is not None
    maximum_file = max(minimum_file, min(maximum_file_literal, capacity // divisor))
    if maximum_file >= capacity:
        return None, None
    return capacity, maximum_file


def retention_forecast(
    observations: Iterable[tuple[float, int]],
    *,
    total_archive_bytes: int,
    archive_source: str,
    read_errors: int = 0,
    invalid_timestamp_rows: int = 0,
) -> dict[str, str]:
    """Estimate newest-row survival using only copied evidence and source defaults.

    The peak rolling-hour byte count is deliberately used instead of the recent
    mean.  One maximum-size segment is reserved because pruning is file-granular.
    These choices bias the estimate toward a shorter, safer retention window.
    """
    capacity, maximum_file = discover_capacity(archive_source)
    valid: list[tuple[float, int]] = []
    for received_ms, row_bytes in observations:
        if (
            isinstance(received_ms, (int, float))
            and math.isfinite(float(received_ms))
            and float(received_ms) > 0
            and isinstance(row_bytes, int)
            and row_bytes > 0
        ):
            valid.append((float(received_ms), row_bytes))
        else:
            invalid_timestamp_rows += 1
    valid.sort(key=lambda item: item[0])

    result = {
        "step_calibration_archive_retention_capacity_status": "ok" if capacity is not None else "unknown",
        "step_calibration_archive_retention_capacity_bytes": str(capacity if capacity is not None else -1),
        "step_calibration_archive_retention_maximum_file_bytes": str(maximum_file if maximum_file is not None else -1),
        "step_calibration_archive_retention_total_bytes": str(max(0, int(total_archive_bytes))),
        "step_calibration_archive_retention_capacity_used_percent": "-1.000",
        "step_calibration_archive_retention_recent_window_hours": "0.000",
        "step_calibration_archive_retention_recent_rows": "0",
        "step_calibration_archive_retention_recent_bytes": "0",
        "step_calibration_archive_recent_ingress_bytes_per_hour": "-1.000",
        "step_calibration_archive_recent_ingress_basis": "peak_rolling_1h_within_latest_6h",
        "step_calibration_archive_estimated_retained_hours": "-1.000",
        "step_calibration_archive_required_delayed_pull_hours": f"{REQUIRED_DELAY_HOURS:.3f}",
        "step_calibration_archive_retention_forecast_status": "insufficient_evidence",
        "step_calibration_archive_retention_evidence_reason": "no_valid_observations" if not valid else "pending",
        "step_calibration_archive_retention_risk": "retention_cannot_be_proven",
        "step_calibration_archive_retention_action": "pull_now_and_repeat_forecast_after_1h_of_valid_observations",
    }
    if capacity is not None:
        result["step_calibration_archive_retention_capacity_used_percent"] = (
            f"{max(0, total_archive_bytes) / capacity * 100:.3f}"
        )
    if not valid:
        return result

    latest_ms = valid[-1][0]
    recent_cutoff_ms = latest_ms - RECENT_WINDOW_HOURS * 3_600_000
    recent = [item for item in valid if item[0] >= recent_cutoff_ms]
    observed_window_hours = min(
        RECENT_WINDOW_HOURS, max(0.0, (latest_ms - recent[0][0]) / 3_600_000)
    )
    recent_bytes = sum(item[1] for item in recent)
    result["step_calibration_archive_retention_recent_window_hours"] = f"{observed_window_hours:.3f}"
    result["step_calibration_archive_retention_recent_rows"] = str(len(recent))
    result["step_calibration_archive_retention_recent_bytes"] = str(recent_bytes)

    left = 0
    rolling_bytes = 0
    peak_hour_bytes = 0
    for right, (timestamp_ms, row_bytes) in enumerate(recent):
        rolling_bytes += row_bytes
        while recent[left][0] < timestamp_ms - 3_600_000:
            rolling_bytes -= recent[left][1]
            left += 1
        peak_hour_bytes = max(peak_hour_bytes, rolling_bytes)
    if peak_hour_bytes > 0:
        result["step_calibration_archive_recent_ingress_bytes_per_hour"] = f"{float(peak_hour_bytes):.3f}"

    evidence_ready = (
        capacity is not None
        and maximum_file is not None
        and read_errors == 0
        and invalid_timestamp_rows == 0
        and observed_window_hours >= MINIMUM_EVIDENCE_HOURS
        and len(recent) >= MINIMUM_EVIDENCE_ROWS
        and peak_hour_bytes > 0
    )
    if not evidence_ready:
        reasons = []
        if capacity is None or maximum_file is None:
            reasons.append("capacity_not_discoverable")
        if read_errors != 0:
            reasons.append("archive_read_error")
        if invalid_timestamp_rows != 0:
            reasons.append("invalid_timestamp_rows")
        if observed_window_hours < MINIMUM_EVIDENCE_HOURS:
            reasons.append("recent_span_below_1h")
        if len(recent) < MINIMUM_EVIDENCE_ROWS:
            reasons.append("recent_rows_below_60")
        if peak_hour_bytes <= 0:
            reasons.append("no_recent_ingress")
        result["step_calibration_archive_retention_evidence_reason"] = ",".join(reasons) or "unknown"
        return result

    usable_capacity = capacity - maximum_file
    estimated_hours = usable_capacity / peak_hour_bytes
    result["step_calibration_archive_estimated_retained_hours"] = f"{estimated_hours:.3f}"
    result["step_calibration_archive_retention_evidence_reason"] = "ready"
    if estimated_hours < REQUIRED_DELAY_HOURS:
        result["step_calibration_archive_retention_forecast_status"] = "too_short"
        result["step_calibration_archive_retention_risk"] = "newest_rows_may_rotate_before_2h_delayed_pull"
        result["step_calibration_archive_retention_action"] = "pull_immediately_after_each_calibration_window"
    elif estimated_hours < REQUIRED_DELAY_HOURS * SAFETY_MARGIN:
        result["step_calibration_archive_retention_forecast_status"] = "thin_margin"
        result["step_calibration_archive_retention_risk"] = "less_than_25_percent_safety_margin_for_2h_pull"
        result["step_calibration_archive_retention_action"] = "pull_immediately_after_final_calibration_window"
    else:
        result["step_calibration_archive_retention_forecast_status"] = "sufficient"
        result["step_calibration_archive_retention_risk"] = "none_for_2h_pull_under_observed_peak_ingress"
        result["step_calibration_archive_retention_action"] = "pull_no_later_than_2h_after_final_calibration_window"
    return result


def _validated_sequence_state(raw_value: object) -> tuple[dict, list[dict], bool, bool]:
    """Decode the durable plan using the app's exact fail-closed contract."""
    if isinstance(raw_value, bytes):
        raw_value = raw_value.decode("utf-8")
    if isinstance(raw_value, str):
        state = json.loads(raw_value)
    elif isinstance(raw_value, dict):
        state = raw_value
    else:
        raise ValueError("unsupported preference type")
    if not isinstance(state, dict) or state.get("version") != 1:
        raise ValueError("invalid schema")
    windows = state.get("windows")
    if not isinstance(windows, list) or len(windows) > len(_STAGES):
        raise ValueError("invalid windows")
    previous_end: int | None = None
    for window, (label, kind, expected, _) in zip(windows, _STAGES):
        if not isinstance(window, dict):
            raise ValueError("invalid window")
        if (
            set(window) != {"label", "kind", "start_ms", "end_ms", "expected_steps"}
            or window.get("label") != label
            or window.get("kind") != kind
            or window.get("expected_steps") != expected
            or type(window.get("start_ms")) is not int
            or type(window.get("end_ms")) is not int
            or window["start_ms"] <= 0
            or window["start_ms"] >= window["end_ms"]
            or (previous_end is not None and window["start_ms"] < previous_end)
        ):
            raise ValueError("invalid window")
        previous_end = window["end_ms"]
    active_index = state.get("activeStageIndex")
    active_start = state.get("activeStageStartMS")
    finish = state.get("activeStageFinishRequestedMS")
    if active_index is None and active_start is None and finish is None:
        active = False
        finishing = False
    elif (
        type(active_index) is int
        and active_index == len(windows)
        and active_index < len(_STAGES)
        and type(active_start) is int
        and active_start > 0
        and (finish is None or type(finish) is int)
    ):
        minimum_duration = _STAGES[active_index][3]
        if finish is not None and finish - active_start < minimum_duration:
            raise ValueError("invalid finish")
        if previous_end is not None and active_start < previous_end:
            raise ValueError("active stage overlaps a completed window")
        active = True
        finishing = finish is not None
    else:
        raise ValueError("invalid active state")
    return state, windows, active, finishing


def completed_sequence_manifest(raw_value: object) -> dict[str, list[dict]]:
    """Recover the exact app manifest only from a complete, idle durable plan."""
    _, windows, active, finishing = _validated_sequence_state(raw_value)
    if len(windows) != len(_STAGES) or active or finishing:
        raise ValueError("sequence is not complete")
    # Copy only the five manifest keys. Preference-only bookkeeping must never
    # leak into or alter the fitter contract.
    return {"windows": [dict(window) for window in windows]}


def sequence_summary(raw_value: object) -> dict[str, str]:
    """Validate the persisted six-stage state without claiming UI visibility."""
    result = {
        "step_calibration_sequence_state": "not_started",
        "step_calibration_sequence_completed_window_count": "0",
        "step_calibration_sequence_total_window_count": str(len(_STAGES)),
        "step_calibration_sequence_active": "0",
        "step_calibration_sequence_finishing": "0",
        "step_calibration_sequence_complete": "0",
        "step_calibration_sequence_state_source": "preferences_absent_default",
        "step_calibration_sequence_ui_visibility_proven": "0",
        "step_calibration_sequence_interpretation": "preferences_state_only_not_ui_visibility",
    }
    if raw_value is None:
        return result
    try:
        _, windows, active, finishing = _validated_sequence_state(raw_value)
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
        result["step_calibration_sequence_state"] = "corrupt"
        result["step_calibration_sequence_completed_window_count"] = "-1"
        result["step_calibration_sequence_state_source"] = "preferences_corrupt"
        return result

    complete = len(windows) == len(_STAGES)
    result["step_calibration_sequence_completed_window_count"] = str(len(windows))
    result["step_calibration_sequence_active"] = "1" if active else "0"
    result["step_calibration_sequence_finishing"] = "1" if finishing else "0"
    result["step_calibration_sequence_complete"] = "1" if complete else "0"
    result["step_calibration_sequence_state_source"] = "preferences_persisted"
    if complete:
        result["step_calibration_sequence_state"] = "complete"
    elif finishing:
        result["step_calibration_sequence_state"] = "finishing"
    elif active:
        result["step_calibration_sequence_state"] = "active"
    else:
        result["step_calibration_sequence_state"] = "ready"
    return result
