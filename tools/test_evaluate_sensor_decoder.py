#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("evaluate_sensor_decoder.py")
SPEC = importlib.util.spec_from_file_location("evaluate_sensor_decoder", MODULE_PATH)
assert SPEC and SPEC.loader
evaluator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(evaluator)


def decoder_label(signal: str, start: int, value: float | None, session: str, control: bool = False) -> dict:
    return {"gap": "GAP-14", "start_rel": start, "end_rel": start + 60,
            "signal": signal, "reference_device": "independent reference",
            "session_id": session, "reference_value": value,
            "pair_age_seconds": 1, "layout_stable": True, "negative_control": control}


def corpus_manifest() -> dict:
    def participant(name: str, split: str, sessions: list[str]) -> dict:
        labels = []
        for index, session in enumerate(sessions):
            for signal, values in (("spo2", [95.0, 96.0, 98.0, 99.0]),
                                   ("skin_temperature", [31.0, 32.0, 33.0, 34.0])):
                for offset, value in enumerate(values):
                    labels.append(decoder_label(signal, index * 1_000 + offset * 70 + (500 if signal == "skin_temperature" else 0),
                                                value, session))
                labels.append(decoder_label(signal, index * 1_000 + 400 + (500 if signal == "skin_temperature" else 0),
                                            None, session, control=True))
        return {"pseudonym": name, "split": split,
                "bundle": {"digest_sha256": "d" * 64, "schema": 4}, "labels": labels}
    return {"schema": 1, "research_only": True, "model_validated": False,
            "production_promotions": 0, "targets": ["GAP-14"],
            "participants": [participant("decoder-dev", "development", ["dev-a", "dev-b"]),
                             participant("decoder-held", "held_out", ["held-a"])]}


def predictions(source: dict, signal: str, error: float = 0, control_value: float | None = None) -> dict:
    rows = []
    for participant in source["participants"]:
        for label in participant["labels"]:
            if label["signal"] != signal:
                continue
            value = control_value if label["negative_control"] else label["reference_value"] + error
            rows.append({"pseudonym": participant["pseudonym"], "start_rel": label["start_rel"],
                         "end_rel": label["end_rel"], "prediction_value": value})
    return {"schema": 1, "research_only": True, "model_validated": False,
            "production_promotions": 0, "model_id": f"{signal}-candidate-v0",
            "signal": signal, "predictions": rows}


class SensorDecoderEvaluationTests(unittest.TestCase):
    def test_reports_perfect_held_out_spo2_without_enabling_decoder(self) -> None:
        source = corpus_manifest()
        report = evaluator.evaluate(source, predictions(source, "spo2"), "spo2")
        self.assertEqual(report["status"], "held_out_metrics_for_review_only")
        self.assertFalse(report["model_validated"])
        self.assertEqual(report["production_promotions"], 0)
        self.assertEqual(report["held_out_mean_absolute_error"], 0)
        self.assertEqual(report["held_out_reference_span"], 4)
        self.assertEqual(report["false_metric_promotions_in_controls"], 0)
        self.assertTrue(all(report["threshold_review"].values()))
        self.assertTrue(report["review_required_even_if_all_gates_pass"])

    def test_detects_numeric_output_for_a_negative_control(self) -> None:
        source = corpus_manifest()
        report = evaluator.evaluate(source, predictions(source, "skin_temperature", control_value=33), "skin_temperature")
        self.assertGreater(report["false_metric_promotions_in_controls"], 0)
        self.assertFalse(report["threshold_review"]["zero_negative_control_promotions"])

    def test_requires_prediction_for_every_admitted_window(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source, "spo2")
        candidate["predictions"].pop()
        with self.assertRaisesRegex(evaluator.EvaluationError, "exactly match"):
            evaluator.evaluate(source, candidate, "spo2")

    def test_rejects_numeric_missing_measurement_prediction(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source, "spo2")
        for row in candidate["predictions"]:
            if row["pseudonym"] == "decoder-held" and row["prediction_value"] == 95:
                row["prediction_value"] = None
                break
        with self.assertRaisesRegex(evaluator.EvaluationError, "require a numeric"):
            evaluator.evaluate(source, candidate, "spo2")

    def test_rejects_duplicate_window(self) -> None:
        source = corpus_manifest()
        candidate = predictions(source, "spo2")
        candidate["predictions"].append(copy.deepcopy(candidate["predictions"][0]))
        with self.assertRaisesRegex(evaluator.EvaluationError, "duplicate decoder"):
            evaluator.evaluate(source, candidate, "spo2")


if __name__ == "__main__":
    unittest.main()
