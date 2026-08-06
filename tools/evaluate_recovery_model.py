#!/usr/bin/env python3
"""Report participant-held-out GAP-13 Recovery calibration evidence only.

The evaluator compares frozen, versioned Recovery candidate scores with a
pre-registered external outcome protocol. It cannot train a model, overwrite a
historical score, or make a candidate model production-valid.
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


def correlation(pairs: list[tuple[float, float]]) -> float | None:
    if len(pairs) < 2:
        return None
    score_mean = sum(score for score, _ in pairs) / len(pairs)
    outcome_mean = sum(outcome for _, outcome in pairs) / len(pairs)
    numerator = sum((score - score_mean) * (outcome - outcome_mean) for score, outcome in pairs)
    score_power = sum((score - score_mean) ** 2 for score, _ in pairs)
    outcome_power = sum((outcome - outcome_mean) ** 2 for _, outcome in pairs)
    if score_power == 0 or outcome_power == 0:
        return None
    return numerator / math.sqrt(score_power * outcome_power)


def concordance(pairs: list[tuple[float, float]]) -> float | None:
    comparable = 0
    concordant = 0
    for index, (score_a, outcome_a) in enumerate(pairs):
        for score_b, outcome_b in pairs[index + 1:]:
            if score_a == score_b or outcome_a == outcome_b:
                continue
            comparable += 1
            concordant += int((score_a > score_b) == (outcome_a > outcome_b))
    return None if comparable == 0 else concordant / comparable


def admitted_labels(document: dict[str, Any], outcome_kind: str) -> dict[tuple[str, float, float], dict[str, Any]]:
    if outcome_kind not in corpus.RECOVERY_OUTCOME_KINDS:
        raise EvaluationError("unsupported recovery outcome kind")
    try:
        corpus.validate(document)
    except corpus.CorpusError as exc:
        raise EvaluationError(f"corpus was not admitted: {exc}") from exc
    if "GAP-13" not in document["targets"]:
        raise EvaluationError("corpus does not declare GAP-13")
    result: dict[tuple[str, float, float], dict[str, Any]] = {}
    for participant in document["participants"]:
        for label in participant["labels"]:
            if label["gap"] != "GAP-13" or label["outcome_kind"] != outcome_kind:
                continue
            window = key(participant["pseudonym"],
                         time(label["start_rel"], "GAP-13.start_rel"),
                         time(label["end_rel"], "GAP-13.end_rel"))
            if window in result:
                raise EvaluationError("admitted corpus contains duplicate GAP-13 outcome windows")
            outcome = integer(label["outcome_score"], "GAP-13.outcome_score")
            result[window] = {"split": participant["split"],
                              "outcome_score": outcome,
                              "outcome_direction": label["outcome_direction"]}
    if not result:
        raise EvaluationError(f"admitted corpus contains no GAP-13 {outcome_kind} labels")
    return result


def read_predictions(document: dict[str, Any]) -> tuple[str, int, dict[tuple[str, float, float], int]]:
    root = exact_object(document,
                        {"schema", "research_only", "model_validated", "production_promotions", "model_id", "model_version", "predictions"},
                        "predictions")
    if integer(root["schema"], "predictions.schema") != SCHEMA:
        raise EvaluationError("unsupported prediction schema")
    if not boolean(root["research_only"], "predictions.research_only"):
        raise EvaluationError("predictions.research_only must remain true")
    if boolean(root["model_validated"], "predictions.model_validated"):
        raise EvaluationError("the evaluator cannot accept a validated model claim")
    if integer(root["production_promotions"], "predictions.production_promotions") != 0:
        raise EvaluationError("the evaluator cannot accept production promotions")
    model_version = integer(root["model_version"], "predictions.model_version")
    if model_version <= 0:
        raise EvaluationError("predictions.model_version must be positive")
    raw = root["predictions"]
    if not isinstance(raw, list) or not raw:
        raise EvaluationError("predictions must be a non-empty array")
    result: dict[tuple[str, float, float], int] = {}
    for index, value in enumerate(raw):
        item = exact_object(value, {"pseudonym", "start_rel", "end_rel", "recovery_score"}, f"predictions[{index}]")
        window = key(text(item["pseudonym"], f"predictions[{index}].pseudonym"),
                     time(item["start_rel"], f"predictions[{index}].start_rel"),
                     time(item["end_rel"], f"predictions[{index}].end_rel"))
        if window in result:
            raise EvaluationError("predictions contain a duplicate Recovery window")
        score = integer(item["recovery_score"], f"predictions[{index}].recovery_score")
        if not 0 <= score <= 100:
            raise EvaluationError(f"predictions[{index}].recovery_score must be 0–100")
        result[window] = score
    return text(root["model_id"], "model_id"), model_version, result


def calibration_bins(pairs: list[tuple[float, float]]) -> list[dict[str, float | int]]:
    bins: list[dict[str, float | int]] = []
    for lower in range(0, 100, 20):
        upper = lower + 19 if lower < 80 else 100
        matching = [(score, outcome) for score, outcome in pairs if lower <= score <= upper]
        if not matching:
            continue
        bins.append({"lower": lower, "upper": upper, "count": len(matching),
                     "mean_recovery_score": sum(score for score, _ in matching) / len(matching),
                     "mean_protocol_outcome_score": sum(outcome for _, outcome in matching) / len(matching)})
    return bins


def evaluate(corpus_document: dict[str, Any], predictions_document: dict[str, Any], outcome_kind: str) -> dict[str, Any]:
    labels = admitted_labels(corpus_document, outcome_kind)
    model_id, model_version, predictions = read_predictions(predictions_document)
    if set(labels) != set(predictions):
        missing = len(set(labels) - set(predictions))
        unexpected = len(set(predictions) - set(labels))
        raise EvaluationError(f"prediction windows must exactly match admitted GAP-13 labels (missing={missing}, unexpected={unexpected})")
    held_out: list[tuple[float, float]] = []
    for window, label in labels.items():
        if label["split"] != "held_out":
            continue
        outcome = float(label["outcome_score"])
        if label["outcome_direction"] == "lower_is_better":
            outcome = 100 - outcome
        held_out.append((float(predictions[window]), outcome))
    if not held_out:
        raise EvaluationError("no held_out predictions supplied")
    residuals = [score - outcome for score, outcome in held_out]
    return {"schema": SCHEMA, "research_only": True, "model_validated": False,
            "production_promotions": 0, "status": "held_out_metrics_for_review_only",
            "target": "GAP-13", "outcome_kind": outcome_kind,
            "model_id": model_id, "model_version": model_version,
            "development_window_count": sum(1 for label in labels.values() if label["split"] == "development"),
            "held_out_window_count": len(held_out),
            "held_out_bias": sum(residuals) / len(residuals),
            "held_out_mean_absolute_error": sum(abs(value) for value in residuals) / len(residuals),
            "held_out_correlation": correlation(held_out),
            "held_out_concordance": concordance(held_out),
            "calibration_bins": calibration_bins(held_out),
            "historical_scores_overwritten": 0,
            "review_required_even_if_metrics_are_favorable": True}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("predictions", type=Path)
    parser.add_argument("--outcome-kind", choices=sorted(corpus.RECOVERY_OUTCOME_KINDS), required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        report = evaluate(read_json(args.corpus, "corpus"), read_json(args.predictions, "predictions"), args.outcome_kind)
    except EvaluationError as exc:
        print(f"RECOVERY_EVALUATION_REJECTED: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
