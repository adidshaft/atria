#!/usr/bin/env python3
"""Report GAP-10 held-out overnight-load calibration without shipping a model.

This accepts only corpus-admitted, externally labelled 0–3 windows and a
local candidate-prediction sidecar.  It is deliberately a research report:
it never trains, validates, promotes, or writes an Atria physiological-load
value.  That keeps the existing HR-only overnight display from becoming a
claimed stress model merely because an offline candidate was evaluated.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
import validate_research_corpus as corpus


SCHEMA = 1
LEVELS = range(4)


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


def time(value: Any, name: str) -> float:
    try:
        result = corpus.finite(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc
    if result < 0 or abs(result * 10 - round(result * 10)) > 0.000_001:
        raise EvaluationError(f"{name} must use the bundle's 0.1-second time axis")
    return round(result, 1)


def key(pseudonym: str, start: float, end: float) -> tuple[str, float, float]:
    return pseudonym, start, end


def admitted_labels(document: dict[str, Any]) -> dict[tuple[str, float, float], tuple[int, str]]:
    try:
        corpus.validate(document)
    except corpus.CorpusError as exc:
        raise EvaluationError(f"corpus was not admitted: {exc}") from exc
    if "GAP-10" not in document["targets"]:
        raise EvaluationError("corpus does not declare GAP-10")

    result: dict[tuple[str, float, float], tuple[int, str]] = {}
    for participant in document["participants"]:
        for label in participant["labels"]:
            if label["gap"] != "GAP-10":
                continue
            window = key(participant["pseudonym"],
                         time(label["start_rel"], "GAP-10.start_rel"),
                         time(label["end_rel"], "GAP-10.end_rel"))
            if window in result:
                raise EvaluationError("admitted corpus contains duplicate GAP-10 windows")
            level = integer(label["reference_level"], "GAP-10.reference_level")
            if level not in LEVELS:
                raise EvaluationError("admitted corpus has an unsupported GAP-10 level")
            result[window] = level, participant["split"]
    if not result:
        raise EvaluationError("admitted corpus contains no GAP-10 labels")
    return result


def read_predictions(document: dict[str, Any]) -> tuple[str, dict[tuple[str, float, float], int]]:
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
    raw = root["predictions"]
    if not isinstance(raw, list) or not raw:
        raise EvaluationError("predictions must be a non-empty array")

    result: dict[tuple[str, float, float], int] = {}
    for index, value in enumerate(raw):
        item = exact_object(value, {"pseudonym", "start_rel", "end_rel", "prediction_level"}, f"predictions[{index}]")
        window = key(text(item["pseudonym"], f"predictions[{index}].pseudonym"),
                     time(item["start_rel"], f"predictions[{index}].start_rel"),
                     time(item["end_rel"], f"predictions[{index}].end_rel"))
        if window in result:
            raise EvaluationError("predictions contain a duplicate overnight-load window")
        level = integer(item["prediction_level"], f"predictions[{index}].prediction_level")
        if level not in LEVELS:
            raise EvaluationError(f"predictions[{index}].prediction_level must be 0–3")
        result[window] = level
    return text(root["model_id"], "model_id"), result


def rate(numerator: int, denominator: int) -> float | None:
    return None if denominator == 0 else numerator / denominator


def evaluate(corpus_document: dict[str, Any], predictions_document: dict[str, Any]) -> dict[str, Any]:
    labels = admitted_labels(corpus_document)
    model_id, predictions = read_predictions(predictions_document)
    if set(labels) != set(predictions):
        missing = len(set(labels) - set(predictions))
        unexpected = len(set(predictions) - set(labels))
        raise EvaluationError(f"prediction windows must exactly match admitted GAP-10 labels (missing={missing}, unexpected={unexpected})")

    held_out = [(expected, predictions[window]) for window, (expected, split) in labels.items() if split == "held_out"]
    if not held_out:
        raise EvaluationError("no held_out predictions supplied")

    per_level: dict[str, dict[str, int | float | None]] = {}
    for level in LEVELS:
        true_positive = sum(expected == level and prediction == level for expected, prediction in held_out)
        false_positive = sum(expected != level and prediction == level for expected, prediction in held_out)
        false_negative = sum(expected == level and prediction != level for expected, prediction in held_out)
        per_level[str(level)] = {
            "support": sum(expected == level for expected, _ in held_out),
            "precision": rate(true_positive, true_positive + false_positive),
            "recall": rate(true_positive, true_positive + false_negative),
        }
    high_true_positive = sum(expected == 3 and prediction == 3 for expected, prediction in held_out)
    high_false_positive = sum(expected != 3 and prediction == 3 for expected, prediction in held_out)
    high_false_negative = sum(expected == 3 and prediction != 3 for expected, prediction in held_out)
    confusion = {
        str(expected): {str(prediction): sum(actual == expected and candidate == prediction
                                              for actual, candidate in held_out)
                        for prediction in LEVELS}
        for expected in LEVELS
    }
    return {
        "schema": SCHEMA,
        "research_only": True,
        "model_validated": False,
        "production_promotions": 0,
        "status": "held_out_metrics_for_review_only",
        "target": "GAP-10",
        "model_id": model_id,
        "development_window_count": sum(1 for _, split in labels.values() if split == "development"),
        "held_out_window_count": len(held_out),
        "mean_absolute_error": sum(abs(expected - prediction) for expected, prediction in held_out) / len(held_out),
        "exact_level_agreement": sum(expected == prediction for expected, prediction in held_out) / len(held_out),
        "high_level_3": {"precision": rate(high_true_positive, high_true_positive + high_false_positive),
                          "recall": rate(high_true_positive, high_true_positive + high_false_negative)},
        "per_level": per_level,
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
        print(f"OVERNIGHT_LOAD_EVALUATION_REJECTED: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
