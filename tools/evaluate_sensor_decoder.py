#!/usr/bin/env python3
"""Evaluate a research-only GAP-14 decoder candidate on held-out sessions.

This reporter is intentionally incapable of enabling a temperature or SpO2
decoder. It measures a locally supplied candidate only against admitted
independent references and returns a review artifact with zero promotions.
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
SIGNALS = {"spo2", "skin_temperature"}


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


def finite(value: Any, name: str) -> float:
    try:
        return corpus.finite(value, name)
    except corpus.CorpusError as exc:
        raise EvaluationError(str(exc)) from exc


def time(value: Any, name: str) -> float:
    result = finite(value, name)
    if result < 0 or abs(result * 10 - round(result * 10)) > 0.000_001:
        raise EvaluationError(f"{name} must use the bundle's 0.1-second time axis")
    return round(result, 1)


def key(pseudonym: str, start: float, end: float) -> tuple[str, float, float]:
    return pseudonym, start, end


def percentile_95(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(0.95 * len(ordered)) - 1)
    return ordered[index]


def correlation(pairs: list[tuple[float, float]]) -> float | None:
    if len(pairs) < 2:
        return None
    expected_mean = sum(expected for expected, _ in pairs) / len(pairs)
    predicted_mean = sum(predicted for _, predicted in pairs) / len(pairs)
    numerator = sum((expected - expected_mean) * (predicted - predicted_mean) for expected, predicted in pairs)
    expected_power = sum((expected - expected_mean) ** 2 for expected, _ in pairs)
    predicted_power = sum((predicted - predicted_mean) ** 2 for _, predicted in pairs)
    if expected_power == 0 or predicted_power == 0:
        return None
    return numerator / math.sqrt(expected_power * predicted_power)


def admitted_labels(document: dict[str, Any], signal: str) -> dict[tuple[str, float, float], dict[str, Any]]:
    if signal not in SIGNALS:
        raise EvaluationError("unsupported decoder signal")
    try:
        corpus.validate(document)
    except corpus.CorpusError as exc:
        raise EvaluationError(f"corpus was not admitted: {exc}") from exc
    if "GAP-14" not in document["targets"]:
        raise EvaluationError("corpus does not declare GAP-14")
    result: dict[tuple[str, float, float], dict[str, Any]] = {}
    for participant in document["participants"]:
        for label in participant["labels"]:
            if label["gap"] != "GAP-14" or label["signal"] != signal:
                continue
            window = key(participant["pseudonym"],
                         time(label["start_rel"], "GAP-14.start_rel"),
                         time(label["end_rel"], "GAP-14.end_rel"))
            if window in result:
                raise EvaluationError("admitted corpus contains duplicate decoder windows")
            result[window] = {"split": participant["split"],
                              "session_id": label["session_id"],
                              "negative_control": label["negative_control"],
                              "reference_value": label["reference_value"]}
    if not result:
        raise EvaluationError(f"admitted corpus contains no GAP-14 {signal} labels")
    return result


def read_predictions(document: dict[str, Any], signal: str) -> tuple[str, dict[tuple[str, float, float], float | None]]:
    root = exact_object(document, {"schema", "research_only", "model_validated", "production_promotions", "model_id", "signal", "predictions"}, "predictions")
    if integer(root["schema"], "predictions.schema") != SCHEMA:
        raise EvaluationError("unsupported prediction schema")
    if not boolean(root["research_only"], "predictions.research_only"):
        raise EvaluationError("predictions.research_only must remain true")
    if boolean(root["model_validated"], "predictions.model_validated"):
        raise EvaluationError("the evaluator cannot accept a validated model claim")
    if integer(root["production_promotions"], "predictions.production_promotions") != 0:
        raise EvaluationError("the evaluator cannot accept production promotions")
    if text(root["signal"], "predictions.signal") != signal:
        raise EvaluationError("prediction signal does not match the requested signal")
    raw = root["predictions"]
    if not isinstance(raw, list) or not raw:
        raise EvaluationError("predictions must be a non-empty array")
    result: dict[tuple[str, float, float], float | None] = {}
    for index, value in enumerate(raw):
        item = exact_object(value, {"pseudonym", "start_rel", "end_rel", "prediction_value"}, f"predictions[{index}]")
        window = key(text(item["pseudonym"], f"predictions[{index}].pseudonym"),
                     time(item["start_rel"], f"predictions[{index}].start_rel"),
                     time(item["end_rel"], f"predictions[{index}].end_rel"))
        if window in result:
            raise EvaluationError("predictions contain a duplicate decoder window")
        result[window] = None if item["prediction_value"] is None else finite(item["prediction_value"], f"predictions[{index}].prediction_value")
    return text(root["model_id"], "model_id"), result


def threshold_review(signal: str, span: float | None, bias: float | None, mae: float | None,
                     p95: float | None, corr: float | None, false_promotions: int,
                     session_count: int) -> dict[str, bool]:
    def within(value: float | None, maximum: float, absolute: bool = False) -> bool:
        if value is None:
            return False
        return (abs(value) if absolute else value) <= maximum

    def at_least(value: float | None, minimum: float) -> bool:
        return value is not None and value >= minimum

    if signal == "spo2":
        return {"reference_span": at_least(span, 4), "absolute_bias": within(bias, 1, absolute=True),
                "mae": within(mae, 2), "p95_absolute_error": within(p95, 4),
                "correlation": at_least(corr, 0.8), "three_sessions": session_count >= 3,
                "zero_negative_control_promotions": false_promotions == 0}
    return {"reference_span": at_least(span, 2), "absolute_bias": within(bias, 0.2, absolute=True),
            "mae": within(mae, 0.3), "correlation": at_least(corr, 0.9),
            "three_sessions": session_count >= 3,
            "zero_negative_control_promotions": false_promotions == 0}


def evaluate(corpus_document: dict[str, Any], predictions_document: dict[str, Any], signal: str) -> dict[str, Any]:
    labels = admitted_labels(corpus_document, signal)
    model_id, predictions = read_predictions(predictions_document, signal)
    if set(labels) != set(predictions):
        missing = len(set(labels) - set(predictions))
        unexpected = len(set(predictions) - set(labels))
        raise EvaluationError(f"prediction windows must exactly match admitted GAP-14 labels (missing={missing}, unexpected={unexpected})")

    held_pairs: list[tuple[float, float]] = []
    false_promotions = 0
    session_ids: set[str] = set()
    held_sessions: set[str] = set()
    for window, label in labels.items():
        prediction = predictions[window]
        session_ids.add(label["session_id"])
        if label["split"] == "held_out":
            held_sessions.add(label["session_id"])
            if label["negative_control"]:
                false_promotions += int(prediction is not None)
            else:
                if prediction is None:
                    raise EvaluationError("measured reference windows require a numeric prediction")
                held_pairs.append((finite(label["reference_value"], "reference_value"), prediction))
        elif label["negative_control"] and prediction is not None:
            # A decoder failing a development negative control cannot be
            # hidden merely by omitting it from the final review artifact.
            false_promotions += 1
    if not held_pairs:
        raise EvaluationError("no held_out measured reference predictions supplied")
    if not held_sessions:
        raise EvaluationError("no held_out sessions supplied")

    errors = [predicted - expected for expected, predicted in held_pairs]
    references = [expected for expected, _ in held_pairs]
    bias = sum(errors) / len(errors)
    mae = sum(abs(error) for error in errors) / len(errors)
    p95 = percentile_95([abs(error) for error in errors])
    span = max(references) - min(references)
    corr = correlation(held_pairs)
    gates = threshold_review(signal, span, bias, mae, p95, corr, false_promotions, len(session_ids))
    return {"schema": SCHEMA, "research_only": True, "model_validated": False,
            "production_promotions": 0, "status": "held_out_metrics_for_review_only",
            "target": "GAP-14", "signal": signal, "model_id": model_id,
            "held_out_measured_pair_count": len(held_pairs),
            "held_out_session_count": len(held_sessions), "all_session_count": len(session_ids),
            "held_out_reference_span": span, "held_out_bias": bias,
            "held_out_mean_absolute_error": mae, "held_out_p95_absolute_error": p95,
            "held_out_correlation": corr, "false_metric_promotions_in_controls": false_promotions,
            "threshold_review": gates,
            "review_required_even_if_all_gates_pass": True}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("predictions", type=Path)
    parser.add_argument("--signal", choices=sorted(SIGNALS), required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        report = evaluate(read_json(args.corpus, "corpus"), read_json(args.predictions, "predictions"), args.signal)
    except EvaluationError as exc:
        print(f"SENSOR_DECODER_EVALUATION_REJECTED: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
