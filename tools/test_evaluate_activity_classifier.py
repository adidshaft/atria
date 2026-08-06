#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("evaluate_activity_classifier.py")
SPEC = importlib.util.spec_from_file_location("evaluate_activity_classifier", MODULE_PATH)
assert SPEC and SPEC.loader
evaluator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluator)


ACTIVITIES = ["walking", "running", "cycling", "strength_training", "other_workout"]


def gap11_label(activity: str, start: int) -> dict:
    return {
        "gap": "GAP-11", "start_rel": start, "end_rel": start + 60,
        "activity_type": activity, "label_source": "user_confirmed",
        "features": {"cadence": True, "orientation": True, "gyroscope": True, "hr_response": True},
    }


def participant(pseudonym: str, split: str) -> dict:
    return {
        "pseudonym": pseudonym,
        "split": split,
        "bundle": {"digest_sha256": "a" * 64, "schema": 4},
        "labels": [gap11_label(activity, index * 70) for index, activity in enumerate(ACTIVITIES)],
    }


def corpus_manifest() -> dict:
    return {
        "schema": 1,
        "research_only": True,
        "model_validated": False,
        "production_promotions": 0,
        "targets": ["GAP-11"],
        "participants": [participant("dev-person", "development"), participant("held-person", "held_out")],
    }


def predictions(corpus: dict, held_out_prediction: str | None = None) -> dict:
    rows = []
    for participant_row in corpus["participants"]:
        for label in participant_row["labels"]:
            prediction = label["activity_type"]
            if participant_row["split"] == "held_out" and label["activity_type"] == "walking" and held_out_prediction:
                prediction = held_out_prediction
            rows.append({"pseudonym": participant_row["pseudonym"],
                         "start_rel": label["start_rel"],
                         "end_rel": label["end_rel"],
                         "prediction": prediction})
    return {"schema": 1, "research_only": True, "model_validated": False,
            "production_promotions": 0, "model_id": "research-activity-v0", "predictions": rows}


class ActivityClassifierEvaluationTests(unittest.TestCase):
    def test_reports_only_held_out_per_class_metrics(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source, held_out_prediction="running")
        report = evaluator.evaluate(source, prediction_rows)
        self.assertEqual(report["status"], "held_out_metrics_for_review_only")
        self.assertFalse(report["model_validated"])
        self.assertEqual(report["production_promotions"], 0)
        self.assertEqual(report["development_window_count"], 5)
        self.assertEqual(report["held_out_window_count"], 5)
        self.assertEqual(report["per_class"]["walking"]["recall"], 0)
        self.assertEqual(report["per_class"]["running"]["precision"], 0.5)

    def test_requires_every_admitted_window_to_have_one_prediction(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source)
        prediction_rows["predictions"].pop()
        with self.assertRaisesRegex(evaluator.EvaluationError, "exactly match"):
            evaluator.evaluate(source, prediction_rows)

    def test_rejects_production_claim_in_prediction_document(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source)
        prediction_rows["model_validated"] = True
        with self.assertRaisesRegex(evaluator.EvaluationError, "validated model claim"):
            evaluator.evaluate(source, prediction_rows)

    def test_rejects_boolean_schema_value(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source)
        prediction_rows["schema"] = True
        with self.assertRaisesRegex(evaluator.EvaluationError, "must be an integer"):
            evaluator.evaluate(source, prediction_rows)

    def test_rejects_duplicate_prediction_window(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source)
        prediction_rows["predictions"].append(copy.deepcopy(prediction_rows["predictions"][0]))
        with self.assertRaisesRegex(evaluator.EvaluationError, "duplicate activity window"):
            evaluator.evaluate(source, prediction_rows)

    def test_allows_explicit_unknown_abstention(self) -> None:
        source = corpus_manifest()
        prediction_rows = predictions(source, held_out_prediction="unknown")
        report = evaluator.evaluate(source, prediction_rows)
        self.assertEqual(report["confusion"]["walking"]["unknown"], 1)
        self.assertEqual(report["per_class"]["walking"]["recall"], 0)


if __name__ == "__main__":
    unittest.main()
