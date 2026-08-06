#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("evaluate_overnight_load_model.py")
SPEC = importlib.util.spec_from_file_location("evaluate_overnight_load_model", MODULE_PATH)
assert SPEC and SPEC.loader
evaluator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluator)


def label(level: int, start: int) -> dict:
    return {
        "gap": "GAP-10", "start_rel": start, "end_rel": start + 60,
        "source": "research_protocol", "reference_level": level,
        "coverage_fraction": 0.95, "qualified_rr": True,
        "motion_context": True, "hr_only": False,
    }


def corpus_manifest() -> dict:
    def participant(pseudonym: str, split: str) -> dict:
        return {
            "pseudonym": pseudonym,
            "split": split,
            "bundle": {"digest_sha256": "c" * 64, "schema": 4},
            "labels": [label(level, level * 70) for level in range(4)],
        }
    return {
        "schema": 1, "research_only": True, "model_validated": False,
        "production_promotions": 0, "targets": ["GAP-10"],
        "participants": [participant("protocol-dev", "development"),
                         participant("protocol-held", "held_out")],
    }


def predictions(source: dict, held_level_3_prediction: int = 3) -> dict:
    rows = []
    for participant in source["participants"]:
        for source_label in participant["labels"]:
            level = source_label["reference_level"]
            if participant["split"] == "held_out" and level == 3:
                level = held_level_3_prediction
            rows.append({"pseudonym": participant["pseudonym"],
                         "start_rel": source_label["start_rel"],
                         "end_rel": source_label["end_rel"],
                         "prediction_level": level})
    return {
        "schema": 1, "research_only": True, "model_validated": False,
        "production_promotions": 0, "model_id": "overnight-load-v0",
        "predictions": rows,
    }


class OvernightLoadEvaluationTests(unittest.TestCase):
    def test_reports_held_out_calibration_without_model_promotion(self) -> None:
        source = corpus_manifest()
        report = evaluator.evaluate(source, predictions(source, held_level_3_prediction=2))
        self.assertEqual(report["target"], "GAP-10")
        self.assertEqual(report["status"], "held_out_metrics_for_review_only")
        self.assertFalse(report["model_validated"])
        self.assertEqual(report["production_promotions"], 0)
        self.assertEqual(report["development_window_count"], 4)
        self.assertEqual(report["held_out_window_count"], 4)
        self.assertEqual(report["mean_absolute_error"], 0.25)
        self.assertEqual(report["exact_level_agreement"], 0.75)
        self.assertEqual(report["high_level_3"]["recall"], 0)

    def test_requires_exactly_one_prediction_per_admitted_window(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"].pop()
        with self.assertRaisesRegex(evaluator.EvaluationError, "exactly match"):
            evaluator.evaluate(source, candidate)

    def test_rejects_production_promotion_claim(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["production_promotions"] = 1
        with self.assertRaisesRegex(evaluator.EvaluationError, "production promotions"):
            evaluator.evaluate(source, candidate)

    def test_rejects_duplicate_window(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"].append(copy.deepcopy(candidate["predictions"][0]))
        with self.assertRaisesRegex(evaluator.EvaluationError, "duplicate overnight-load"):
            evaluator.evaluate(source, candidate)

    def test_rejects_out_of_range_prediction_level(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source)
        candidate["predictions"][0]["prediction_level"] = 4
        with self.assertRaisesRegex(evaluator.EvaluationError, "must be 0–3"):
            evaluator.evaluate(source, candidate)


if __name__ == "__main__":
    unittest.main()
