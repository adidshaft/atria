#!/usr/bin/env python3
"""Fail-closed validator for Atria's externally labelled P2 research corpus.

This is deliberately a corpus *admission* tool, never a model trainer or a
promotion tool. It makes the required participant-separated evaluation contract
machine-checkable before a bundle can be used for overnight-load, activity-type,
sleep-stage, or sensor-decoder research.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SCHEMA = 1
TARGETS = {"GAP-10", "GAP-11", "GAP-12", "GAP-14"}
SPLITS = {"development", "held_out"}
LOAD_SOURCES = {"controlled_intervention", "validated_questionnaire", "research_protocol"}
STAGE_SOURCES = {"polysomnography", "defensible_reference"}
ACTIVITIES = {"walking", "running", "cycling", "strength_training", "other_workout"}


class CorpusError(ValueError):
    pass


def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CorpusError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
    except (OSError, UnicodeError, json.JSONDecodeError, CorpusError) as exc:
        raise CorpusError(f"unable to read corpus manifest: {type(exc).__name__}: {exc}") from exc
    if not isinstance(value, dict):
        raise CorpusError("corpus manifest must be a JSON object")
    return value


def exact_object(value: Any, required: set[str], optional: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorpusError(f"{name} must be an object")
    keys = set(value)
    if not required <= keys or not keys <= required | optional:
        raise CorpusError(f"{name} has missing or unknown fields")
    return value


def text(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise CorpusError(f"{name} must be a trimmed non-empty string")
    return value


def integer(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise CorpusError(f"{name} must be an integer")
    return value


def finite(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise CorpusError(f"{name} must be a finite number")
    return float(value)


def boolean(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        raise CorpusError(f"{name} must be boolean")
    return value


def validate_bundle(bundle: Any, participant: str, targets: set[str]) -> None:
    item = exact_object(bundle, {"digest_sha256", "schema"}, set(), f"{participant}.bundle")
    digest = text(item["digest_sha256"], f"{participant}.bundle.digest_sha256")
    if len(digest) != 64 or any(char not in "0123456789abcdef" for char in digest.lower()):
        raise CorpusError(f"{participant}.bundle.digest_sha256 must be lowercase-compatible SHA-256")
    minimum_schema = 4 if "GAP-12" in targets else 3
    if integer(item["schema"], f"{participant}.bundle.schema") < minimum_schema:
        raise CorpusError(
            f"{participant}.bundle.schema must be Atria research schema {minimum_schema} or newer"
        )


def validate_window(label: dict[str, Any], prefix: str) -> tuple[float, float]:
    start = finite(label["start_rel"], f"{prefix}.start_rel")
    end = finite(label["end_rel"], f"{prefix}.end_rel")
    if start < 0 or end <= start:
        raise CorpusError(f"{prefix} has invalid time alignment")
    return start, end


def validate_gap10(label: dict[str, Any], prefix: str) -> None:
    item = exact_object(label, {"gap", "start_rel", "end_rel", "source", "coverage_fraction", "qualified_rr", "motion_context", "hr_only"}, set(), prefix)
    validate_window(item, prefix)
    if text(item["source"], f"{prefix}.source") not in LOAD_SOURCES:
        raise CorpusError(f"{prefix} requires an external overnight-load source")
    if not 0 < finite(item["coverage_fraction"], f"{prefix}.coverage_fraction") <= 1:
        raise CorpusError(f"{prefix}.coverage_fraction must be in (0, 1]")
    if not boolean(item["qualified_rr"], f"{prefix}.qualified_rr"):
        raise CorpusError(f"{prefix} lacks qualified RR evidence")
    if not boolean(item["motion_context"], f"{prefix}.motion_context"):
        raise CorpusError(f"{prefix} lacks motion/wakefulness context")
    if boolean(item["hr_only"], f"{prefix}.hr_only"):
        raise CorpusError(f"{prefix} is HR-only and cannot be an overnight-load validation label")


def validate_gap11(label: dict[str, Any], prefix: str) -> None:
    item = exact_object(label, {"gap", "start_rel", "end_rel", "activity_type", "label_source", "features"}, set(), prefix)
    start, end = validate_window(item, prefix)
    if end - start < 30:
        raise CorpusError(f"{prefix} must span at least 30 seconds")
    if text(item["activity_type"], f"{prefix}.activity_type") not in ACTIVITIES:
        raise CorpusError(f"{prefix} has unsupported activity type")
    if text(item["label_source"], f"{prefix}.label_source") != "user_confirmed":
        raise CorpusError(f"{prefix} requires a user-confirmed activity label")
    features = exact_object(item["features"], {"cadence", "orientation", "gyroscope", "hr_response"}, set(), f"{prefix}.features")
    for feature in features:
        if not boolean(features[feature], f"{prefix}.features.{feature}"):
            raise CorpusError(f"{prefix} lacks required {feature} evidence")


def validate_gap12(label: dict[str, Any], prefix: str) -> None:
    item = exact_object(label, {"gap", "start_rel", "end_rel", "source", "stage", "atria_derived"}, set(), prefix)
    validate_window(item, prefix)
    if text(item["source"], f"{prefix}.source") not in STAGE_SOURCES:
        raise CorpusError(f"{prefix} requires PSG or another defensible external sleep reference")
    if text(item["stage"], f"{prefix}.stage") not in {"wake", "light", "deep", "rem"}:
        raise CorpusError(f"{prefix} has unsupported sleep stage")
    if boolean(item["atria_derived"], f"{prefix}.atria_derived"):
        raise CorpusError(f"{prefix} cannot use an Atria-derived stage as a validation target")


def validate_gap14(label: dict[str, Any], prefix: str) -> None:
    item = exact_object(label, {"gap", "start_rel", "end_rel", "reference_device", "pair_age_seconds", "layout_stable", "negative_control"}, set(), prefix)
    validate_window(item, prefix)
    text(item["reference_device"], f"{prefix}.reference_device")
    if not 0 <= finite(item["pair_age_seconds"], f"{prefix}.pair_age_seconds") <= 2:
        raise CorpusError(f"{prefix}.pair_age_seconds must be within the documented 2-second gate")
    if not boolean(item["layout_stable"], f"{prefix}.layout_stable"):
        raise CorpusError(f"{prefix} lacks stable record-layout evidence")
    if not boolean(item["negative_control"], f"{prefix}.negative_control"):
        raise CorpusError(f"{prefix} lacks a negative-control declaration")


VALIDATORS = {"GAP-10": validate_gap10, "GAP-11": validate_gap11, "GAP-12": validate_gap12, "GAP-14": validate_gap14}


def validate(document: dict[str, Any]) -> dict[str, Any]:
    root = exact_object(document, {"schema", "research_only", "model_validated", "production_promotions", "targets", "participants"}, set(), "manifest")
    if integer(root["schema"], "schema") != SCHEMA:
        raise CorpusError("unsupported corpus schema")
    if not boolean(root["research_only"], "research_only"):
        raise CorpusError("research_only must remain true")
    if boolean(root["model_validated"], "model_validated"):
        raise CorpusError("the corpus validator cannot declare a model validated")
    if integer(root["production_promotions"], "production_promotions") != 0:
        raise CorpusError("the corpus validator cannot promote a production metric")
    targets = root["targets"]
    if not isinstance(targets, list) or not targets or any(not isinstance(target, str) for target in targets):
        raise CorpusError("targets must be a non-empty string array")
    if set(targets) - TARGETS or len(set(targets)) != len(targets):
        raise CorpusError("targets contain unsupported or duplicate gaps")
    participants = root["participants"]
    if not isinstance(participants, list) or len(participants) < 2:
        raise CorpusError("at least two participant-separated records are required")

    seen: set[str] = set()
    split_by_target: dict[str, set[str]] = defaultdict(set)
    label_counts: Counter[str] = Counter()
    for index, raw in enumerate(participants):
        prefix = f"participants[{index}]"
        item = exact_object(raw, {"pseudonym", "split", "bundle", "labels"}, set(), prefix)
        pseudonym = text(item["pseudonym"], f"{prefix}.pseudonym")
        if pseudonym in seen:
            raise CorpusError(f"participant leakage: pseudonym appears more than once: {pseudonym}")
        seen.add(pseudonym)
        split = text(item["split"], f"{prefix}.split")
        if split not in SPLITS:
            raise CorpusError(f"{prefix}.split must be development or held_out")
        validate_bundle(item["bundle"], prefix, set(targets))
        labels = item["labels"]
        if not isinstance(labels, list) or not labels:
            raise CorpusError(f"{prefix}.labels must be non-empty")
        previous_end = -1.0
        for label_index, label in enumerate(labels):
            label_prefix = f"{prefix}.labels[{label_index}]"
            if not isinstance(label, dict):
                raise CorpusError(f"{label_prefix} must be an object")
            gap = text(label.get("gap"), f"{label_prefix}.gap")
            if gap not in targets:
                raise CorpusError(f"{label_prefix} is not declared in targets")
            VALIDATORS[gap](label, label_prefix)
            start, end = validate_window(label, label_prefix)
            if start < previous_end:
                raise CorpusError(f"{label_prefix} overlaps a prior label for the same participant")
            previous_end = end
            split_by_target[gap].add(split)
            label_counts[gap] += 1

    for target in targets:
        if split_by_target[target] != SPLITS:
            raise CorpusError(f"{target} requires both development and held_out participants")
    return {
        "schema": SCHEMA,
        "research_only": True,
        "model_validated": False,
        "production_promotions": 0,
        "status": "admitted_for_external_evaluation_only",
        "participants": len(seen),
        "labels_by_target": dict(sorted(label_counts.items())),
        "targets": sorted(targets),
        "manifest_sha256": hashlib.sha256(json.dumps(document, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        result = validate(read_json(args.manifest))
    except CorpusError as exc:
        print(f"CORPUS_REJECTED: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
