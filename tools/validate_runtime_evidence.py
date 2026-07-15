#!/usr/bin/env python3
"""Fail-closed validation for copied workout, route, and strap-step authorities."""

from __future__ import annotations

import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Callable


MAXIMUM_STEP_COUNT = 10_000_000


class EvidenceError(ValueError):
    pass


def _number(value: object, *, minimum: float | None = None) -> float:
    if type(value) not in (int, float) or not math.isfinite(float(value)):
        raise EvidenceError("expected finite number")
    result = float(value)
    if minimum is not None and result < minimum:
        raise EvidenceError("number below minimum")
    return result


def _integer(value: object, *, minimum: int = 0, maximum: int | None = None) -> int:
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise EvidenceError("expected bounded integer")
    return value


def _text(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvidenceError("expected nonempty text")
    return value


def _foundation_date(value: object) -> float:
    # JSONEncoder's default Date strategy is seconds since 2001.
    return _number(value)


def _iso_date(value: object) -> str:
    text = _text(value)
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise EvidenceError("invalid ISO-8601 date") from exc
    if parsed.tzinfo is None:
        raise EvidenceError("ISO-8601 date lacks timezone")
    return text


def _object(value: object) -> dict:
    if not isinstance(value, dict):
        raise EvidenceError("expected object")
    return value


def _array(value: object) -> list:
    if not isinstance(value, list):
        raise EvidenceError("expected array")
    return value


def _json(path: Path) -> dict:
    try:
        return _object(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"invalid JSON: {exc}") from exc


def _validate_point(point: object) -> None:
    row = _object(point)
    latitude = _number(row.get("latitude"))
    longitude = _number(row.get("longitude"))
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise EvidenceError("coordinate out of range")
    _number(row.get("altitude"))
    _iso_date(row.get("timestamp"))
    _number(row.get("horizontalAccuracy"), minimum=0)
    if "verticalAccuracy" in row and row["verticalAccuracy"] is not None:
        _number(row["verticalAccuracy"])
    if "startsNewSegment" in row and row["startsNewSegment"] is not None:
        if type(row["startsNewSegment"]) is not bool:
            raise EvidenceError("invalid segment marker")


def validate_pending_workout(path: Path) -> None:
    row = _json(path)
    _foundation_date(row.get("startedAt"))
    if row.get("endedAt") is not None:
        _foundation_date(row["endedAt"])
    _text(row.get("activityType"))
    _array(row.get("strengthSets"))
    _array(row.get("excludedIntervals"))
    _integer(row.get("startingStepCount"), maximum=MAXIMUM_STEP_COUNT)
    _integer(row.get("pausedStepCount"), maximum=MAXIMUM_STEP_COUNT)
    _number(row.get("startingDayStrain"), minimum=0)
    _integer(row.get("persistenceRevision"))
    if type(row.get("stepAccountingIsComplete")) is not bool:
        raise EvidenceError("invalid step accounting flag")


def validate_active_route(path: Path) -> int:
    row = _json(path)
    if _integer(row.get("schema")) != 1:
        raise EvidenceError("unsupported route checkpoint schema")
    _text(row.get("activityType"))
    _iso_date(row.get("startedAt"))
    _iso_date(row.get("updatedAt"))
    points = _array(row.get("points"))
    for point in points:
        _validate_point(point)
    _number(row.get("distanceMeters"), minimum=0)
    _number(row.get("elevationGainMeters"), minimum=0)
    _number(row.get("accumulatedPauseDuration"), minimum=0)
    persisted = row.get("persistedPointCount")
    if persisted is not None:
        return _integer(persisted)
    return len(points)


def validate_route_points(path: Path) -> int:
    count = 0
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    raise EvidenceError("blank route journal line")
                try:
                    point = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise EvidenceError(f"invalid route journal JSON: {exc}") from exc
                _validate_point(point)
                count += 1
    except (OSError, UnicodeDecodeError) as exc:
        raise EvidenceError(f"unreadable route journal: {exc}") from exc
    return count


def validate_pending_route_transaction(path: Path) -> None:
    row = _json(path)
    if _integer(row.get("schema")) != 1:
        raise EvidenceError("unsupported route transaction schema")
    if row.get("operation") not in {"edit", "delete"}:
        raise EvidenceError("invalid route transaction operation")
    _text(row.get("oldWorkoutID"))
    _iso_date(row.get("createdAt"))


def validate_step_ledger(path: Path) -> None:
    row = _json(path)
    if _integer(row.get("schema")) != 1:
        raise EvidenceError("unsupported step-ledger schema")
    _text(row.get("segmentID"))
    _foundation_date(row.get("segmentStartedAt"))
    _foundation_date(row.get("updatedAt"))
    segment = _integer(row.get("segmentSteps"), maximum=MAXIMUM_STEP_COUNT)
    raw_segment = _integer(row.get("segmentRawSteps"), maximum=MAXIMUM_STEP_COUNT)
    cumulative = _integer(row.get("cumulativeSteps"), maximum=MAXIMUM_STEP_COUNT)
    raw_cumulative = _integer(row.get("cumulativeRawSteps"), maximum=MAXIMUM_STEP_COUNT)
    if cumulative < segment or raw_cumulative < raw_segment:
        raise EvidenceError("cumulative ledger count regressed below segment")
    if row.get("deviceTimestamp") is not None:
        _integer(row["deviceTimestamp"], minimum=1, maximum=0xFFFFFFFF)
    if row.get("state") is not None and not isinstance(row["state"], str):
        raise EvidenceError("invalid step-ledger state")


def validate_saved_route(path: Path) -> tuple[str, str]:
    row = _json(path)
    route_id = _text(row.get("id"))
    workout_id = _text(row.get("workoutID"))
    _text(row.get("activityType"))
    _iso_date(row.get("startedAt"))
    _iso_date(row.get("endedAt"))
    points = _array(row.get("points"))
    for point in points:
        _validate_point(point)
    _number(row.get("distanceMeters"), minimum=0)
    _number(row.get("elevationGainMeters"), minimum=0)
    return route_id, workout_id


def validate_saved_routes(directory: Path) -> int:
    if not directory.is_dir():
        raise EvidenceError("saved route path is not a directory")
    route_ids: set[str] = set()
    workout_ids: set[str] = set()
    files = sorted(directory.rglob("*"))
    if any(path.is_file() and path.suffix != ".json" for path in files):
        raise EvidenceError("unexpected saved-route file type")
    count = 0
    for path in files:
        if not path.is_file():
            continue
        route_id, workout_id = validate_saved_route(path)
        if route_id in route_ids or workout_id in workout_ids:
            raise EvidenceError("duplicate route or workout identity")
        route_ids.add(route_id)
        workout_ids.add(workout_id)
        count += 1
    return count


def validate_runtime_state(root: Path) -> dict[str, str]:
    checks: tuple[tuple[str, Path, Callable[[Path], object]], ...] = (
        ("pending_workout_intent", root / "pending-workout-intent-v1.json", validate_pending_workout),
        ("active_workout_route", root / "active-workout-route.json", validate_active_route),
        ("active_workout_route_points", root / "active-workout-route.points.ndjson", validate_route_points),
        ("pending_workout_route_transaction", root / "pending-workout-route-transaction.json", validate_pending_route_transaction),
        ("strap_step_ledger", root / "atria-strap-step-ledger.json", validate_step_ledger),
        ("saved_workout_routes", root / "atria-workout-routes", validate_saved_routes),
    )
    result: dict[str, str] = {}
    present = 0
    invalid = 0
    active_route_count: int | None = None
    journal_count: int | None = None
    for label, path, validator in checks:
        if not path.exists():
            result[f"runtime_{label}_validation"] = "missing"
            continue
        present += 1
        try:
            value = validator(path)
            result[f"runtime_{label}_validation"] = "ok"
            if label == "active_workout_route":
                active_route_count = int(value)
            elif label == "active_workout_route_points":
                journal_count = int(value)
            elif label == "saved_workout_routes":
                result["runtime_saved_workout_route_count"] = str(int(value))
        except (EvidenceError, TypeError, ValueError):
            result[f"runtime_{label}_validation"] = "invalid"
            invalid += 1
    if active_route_count is not None and journal_count is not None and active_route_count != journal_count:
        result["runtime_active_route_point_count_consistency"] = "invalid"
        invalid += 1
    elif active_route_count is not None and journal_count is not None:
        result["runtime_active_route_point_count_consistency"] = "ok"
    else:
        result["runtime_active_route_point_count_consistency"] = "not_applicable"
    result["runtime_evidence_present_artifacts"] = str(present)
    result["runtime_evidence_invalid_artifacts"] = str(invalid)
    result["runtime_evidence_validation_status"] = (
        "invalid" if invalid else ("empty" if present == 0 else "ok")
    )
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_runtime_evidence.py <authoritative-runtime-state-dir>", file=sys.stderr)
        return 64
    result = validate_runtime_state(Path(argv[1]))
    for key in sorted(result):
        print(f"{key}={result[key]}")
    return 2 if result["runtime_evidence_validation_status"] == "invalid" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
