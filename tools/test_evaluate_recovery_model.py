#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("evaluate_recovery_model.py")
SPEC = importlib.util.spec_from_file_location("evaluate_recovery_model", MODULE_PATH)
assert SPEC and SPEC.loader
evaluator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluator)


def outcome(score: int, start: int) -> dict:
    return {"gap": "GAP-13", "start_rel": start, "end_rel": start + 60,
            "outcome_kind": "reported_fatigue", "outcome_score": score,
            "outcome_direction": "lower_is_better", "source": "validated_questionnaire"}


def corpus_manifest() -> dict:
    def participant(name: str, split: str) -> dict:
        return {"pseudonym": name, "split": split,
                "bundle": {"digest_sha256": "e" * 64, "schema": 5},
                "labels": [outcome(20, 0), outcome(45, 70), outcome(70, 140), outcome(90, 210)]}
    return {"schema": 1, "research_only": True, "model_validated": False,
            "production_promotions": 0, "targets": ["GAP-13"],
            "participants": [participant("recovery-dev", "development"),
                             participant("recovery-held", "held_out")]}


def predictions(source: dict) -> dict:
    rows = []
    for participant in source["participants"]:
        for label in participant["labels"]:
            rows.append({"pseudonym": participant["pseudonym"], "start_rel": label["start_rel"],
                         "end_rel": label["end_rel"], "recovery_score": 100 - label["outcome_score"]})
    return {"schema": 1, "research_only": True, "model_validated": False,
            "production_promotions": 0, "model_id": "recovery-candidate", "model_version": 3,
            "predictions": rows}


class RecoveryModelEvaluationTests(unittest.TestCase):
    def test_reports_held_out_calibration_without_rewriting_history(self) -> None:
        source = corpus_manifest()
        report = evaluator.evaluate(source, predictions(source), "reported_fatigue")
        self.assertEqual(report["status"], "held_out_metrics_for_review_only")
        self.assertFalse(report["model_validated"])
        self.assertEqual(report["production_promotions"], 0)
        self.assertEqual(report["model_version"], 3)
        self.assertEqual(report["held_out_mean_absolute_error"], 0)
        self.assertEqual(report["held_out_correlation"], 1)
        self.assertEqual(report["held_out_concordance"], 1)
        self.assertEqual(report["historical_scores_overwritten"], 0)

    def test_requires_every_admitted_outcome_window(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"].pop()
        with self.assertRaisesRegex(evaluator.EvaluationError, "exactly match"):
            evaluator.evaluate(source, candidate, "reported_fatigue")

    def test_rejects_production_claim(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["model_validated"] = True
        with self.assertRaisesRegex(evaluator.EvaluationError, "validated model claim"):
            evaluator.evaluate(source, candidate, "reported_fatigue")

    def test_rejects_duplicate_prediction(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"].append(copy.deepcopy(candidate["predictions"][0]))
        with self.assertRaisesRegex(evaluator.EvaluationError, "duplicate Recovery"):
            evaluator.evaluate(source, candidate, "reported_fatigue")

    def test_rejects_out_of_range_score(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"][0]["recovery_score"] = 101
        with self.assertRaisesRegex(evaluator.EvaluationError, "must be 0–100"):
            evaluator.evaluate(source, candidate, "reported_fatigue")


if __name__ == "__main__":
    unittest.main()
