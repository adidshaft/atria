#!/usr/bin/env python3
"""Evaluate activity-type predictions only against admitted held-out people.

This is intentionally an offline research reporter.  It accepts no training
data, makes no production decision, and refuses any corpus that has not first
passed ``validate_research_corpus.py``.  Its only job is to make GAP-11's
participant-level, per-class precision/recall requirement reproducible once
real consented labels and model predictions are available.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
import validate_research_corpus as corpus


SCHEMA = 1
UNKNOWN = "unknown"
PREDICTIONS = set(corpus.ACTIVITIES) | {UNKNOWN}


class EvaluationError(ValueError):
    pass


def read_json(path: Path, name: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=corpus.reject_duplicates)
    except (OSError, UnicodeError, json.JSONDecodeError, corpus.CorpusError) as exc:
        raise EvaluationError(f"unable to read {name}: {type(exc).__name__}: {exc}") from exc
    if not isinstance(value, dict):
        raise EvaluationError(f"{name} must be a JSON object")
    return value


def finite_time(value: Any, name: str) -> float:
    try:
        result = corpus.finite(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc
    if result < 0 or abs(result * 10 - round(result * 10)) > 0.000_001:
        raise EvaluationError(f"{name} must use the bundle's 0.1-second time axis")
    return round(result, 1)


def exact_object(value: Any, required: set[str], name: str) -> dict[str, Any]:
    try:
        return corpus.exact_object(value, required, set(), name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc


def text(value: Any, name: str) -> str:
    try:
        return corpus.text(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc


def integer(value: Any, name: str) -> int:
    try:
        return corpus.integer(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc


def boolean(value: Any, name: str) -> bool:
    try:
        return corpus.boolean(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc


def prediction_key(pseudonym: str, start_rel: float, end_rel: float) -> tuple[str, float, float]:
    return pseudonym, start_rel, end_rel


def admitted_gap11_labels(document: dict[str, Any]) -> dict[tuple[str, float, float], dict[str, str]]:
    try:
        corpus.validate(document)
    except corpus.CorpusError as exc:
        raise EvaluationError(f"corpus was not admitted: {exc}") from exc
    if "GAP-11" not in document["targets"]:
        raise EvaluationError("corpus does not declare GAP-11")

    labels: dict[tuple[str, float, float], dict[str, str]] = {}
    for participant in document["participants"]:
        pseudonym = participant["pseudonym"]
        split = participant["split"]
        for label in participant["labels"]:
            if label["gap"] != "GAP-11":
                continue
            start = finite_time(label["start_rel"], "GAP-11.start_rel")
            end = finite_time(label["end_rel"], "GAP-11.end_rel")
            key = prediction_key(pseudonym, start, end)
            if key in labels:
                raise EvaluationError("admitted corpus contains duplicate GAP-11 windows")
            labels[key] = {
                "expected": label["activity_type"],
                "split": split,
            }
    if not labels:
        raise EvaluationError("admitted corpus contains no GAP-11 labels")
    return labels


def read_predictions(document: dict[str, Any]) -> tuple[str, dict[tuple[str, float, float], str]]:
    root = exact_object(document,
                        {"schema", "research_only", "model_validated", "production_promotions", "model_id", "predictions"},
                        "predictions")
    if integer(root["schema"], "predictions.schema") != SCHEMA:
        raise EvaluationError("unsupported prediction schema")
    if not boolean(root["research_only"], "predictions.research_only"):
        raise EvaluationError("predictions.research_only must remain true")
    if boolean(root["model_validated"], "predictions.model_validated"):
        raise EvaluationError("the evaluator cannot accept a validated model claim")
    if integer(root["production_promotions"], "predictions.production_promotions") != 0:
        raise EvaluationError("the evaluator cannot accept production promotions")
    model_id = text(root["model_id"], "model_id")
    raw_predictions = root["predictions"]
    if not isinstance(raw_predictions, list) or not raw_predictions:
        raise EvaluationError("predictions must be a non-empty array")

    result: dict[tuple[str, float, float], str] = {}
    for index, raw in enumerate(raw_predictions):
        item = exact_object(raw, {"pseudonym", "start_rel", "end_rel", "prediction"}, f"predictions[{index}]")
        key = prediction_key(text(item["pseudonym"], f"predictions[{index}].pseudonym"),
                             finite_time(item["start_rel"], f"predictions[{index}].start_rel"),
                             finite_time(item["end_rel"], f"predictions[{index}].end_rel"))
        if key in result:
            raise EvaluationError("predictions contain a duplicate activity window")
        prediction = text(item["prediction"], f"predictions[{index}].prediction")
        if prediction not in PREDICTIONS:
            raise EvaluationError(f"predictions[{index}] has unsupported prediction")
        result[key] = prediction
    return model_id, result


def safe_rate(numerator: int, denominator: int) -> float | None:
    return None if denominator == 0 else numerator / denominator


def evaluate(corpus_document: dict[str, Any], predictions_document: dict[str, Any]) -> dict[str, Any]:
    labels = admitted_gap11_labels(corpus_document)
    model_id, predictions = read_predictions(predictions_document)
    if set(predictions) != set(labels):
        missing = len(set(labels) - set(predictions))
        unexpected = len(set(predictions) - set(labels))
        raise EvaluationError(f"prediction windows must exactly match admitted GAP-11 labels (missing={missing}, unexpected={unexpected})")

    held_out = [(labels[key]["expected"], prediction)
                for key, prediction in predictions.items()
                if labels[key]["split"] == "held_out"]
    if not held_out:
        raise EvaluationError("no held_out predictions supplied")

    # `unknown` is an explicit abstention, not a sixth activity class.
    per_class: dict[str, dict[str, int | float | None]] = {}
    for activity in sorted(corpus.ACTIVITIES):
        true_positive = sum(expected == activity and predicted == activity for expected, predicted in held_out)
        false_positive = sum(expected != activity and predicted == activity for expected, predicted in held_out)
        false_negative = sum(expected == activity and predicted != activity for expected, predicted in held_out)
        support = sum(expected == activity for expected, _ in held_out)
        per_class[activity] = {
            "support": support,
            "true_positive": true_positive,
            "false_positive": false_positive,
            "false_negative": false_negative,
            "precision": safe_rate(true_positive, true_positive + false_positive),
            "recall": safe_rate(true_positive, true_positive + false_negative),
        }

    confusion: dict[str, dict[str, int]] = {}
    for expected in sorted(corpus.ACTIVITIES):
        confusion[expected] = {
            predicted: sum(actual == expected and candidate == predicted for actual, candidate in held_out)
            for predicted in sorted(PREDICTIONS)
        }

    development_count = sum(1 for item in labels.values() if item["split"] == "development")
    return {
        "schema": SCHEMA,
        "research_only": True,
        "model_validated": False,
        "production_promotions": 0,
        "status": "held_out_metrics_for_review_only",
        "model_id": model_id,
        "development_window_count": development_count,
        "held_out_window_count": len(held_out),
        "per_class": per_class,
        "confusion": confusion,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("predictions", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        report = evaluate(read_json(args.corpus, "corpus"), read_json(args.predictions, "predictions"))
    except EvaluationError as exc:
        print(f"ACTIVITY_EVALUATION_REJECTED: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
