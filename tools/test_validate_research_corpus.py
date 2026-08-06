#!/usr/bin/env python3
from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("validate_research_corpus.py")
SPEC = importlib.util.spec_from_file_location("validate_research_corpus", MODULE_PATH)
assert SPEC and SPEC.loader
corpus = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(corpus)


def label(gap: str, start: float) -> dict:
    common = {"gap": gap, "start_rel": start, "end_rel": start + 60}
    if gap == "GAP-10":
        return common | {"source": "research_protocol", "reference_level": 2, "coverage_fraction": 0.95,
                         "qualified_rr": True, "motion_context": True, "hr_only": False}
    if gap == "GAP-11":
        return common | {"activity_type": "walking", "label_source": "user_confirmed",
                         "features": {"cadence": True, "orientation": True, "gyroscope": True, "hr_response": True}}
    if gap == "GAP-12":
        return common | {"source": "polysomnography", "stage": "deep", "atria_derived": False}
    return common | {"signal": "spo2", "reference_device": "reference oximeter", "pair_age_seconds": 1,
                     "layout_stable": True, "negative_control": True}


def participant(name: str, split: str) -> dict:
    return {
        "pseudonym": name,
        "split": split,
        "bundle": {"digest_sha256": "a" * 64, "schema": 4},
        "labels": [label(gap, index * 70) for index, gap in enumerate(["GAP-10", "GAP-11", "GAP-12", "GAP-14"])],
    }


def manifest() -> dict:
    return {
        "schema": 1,
        "research_only": True,
        "model_validated": False,
        "production_promotions": 0,
        "targets": ["GAP-10", "GAP-11", "GAP-12", "GAP-14"],
        "participants": [participant("participant-development", "development"), participant("participant-held-out", "held_out")],
    }


class ResearchCorpusTests(unittest.TestCase):
    def test_admits_participant_separated_external_corpus_without_promotion(self) -> None:
        result = corpus.validate(manifest())
        self.assertEqual(result["status"], "admitted_for_external_evaluation_only")
        self.assertFalse(result["model_validated"])
        self.assertEqual(result["production_promotions"], 0)
        self.assertEqual(result["labels_by_target"], {"GAP-10": 2, "GAP-11": 2, "GAP-12": 2, "GAP-14": 2})

    def test_rejects_participant_leakage_between_splits(self) -> None:
        value = manifest()
        value["participants"][1]["pseudonym"] = value["participants"][0]["pseudonym"]
        with self.assertRaisesRegex(corpus.CorpusError, "participant leakage"):
            corpus.validate(value)

    def test_rejects_hr_only_overnight_load_label(self) -> None:
        value = manifest()
        value["participants"][0]["labels"][0]["hr_only"] = True
        with self.assertRaisesRegex(corpus.CorpusError, "HR-only"):
            corpus.validate(value)

    def test_rejects_unscaled_overnight_load_reference(self) -> None:
        value = manifest()
        value["participants"][0]["labels"][0]["reference_level"] = 4
        with self.assertRaisesRegex(corpus.CorpusError, "0–3 scale"):
            corpus.validate(value)

    def test_rejects_atria_generated_sleep_stage_target(self) -> None:
        value = manifest()
        value["participants"][1]["labels"][2]["atria_derived"] = True
        with self.assertRaisesRegex(corpus.CorpusError, "Atria-derived"):
            corpus.validate(value)

    def test_rejects_pre_provenance_bundle_for_sleep_stage_validation(self) -> None:
        value = manifest()
        value["participants"][0]["bundle"]["schema"] = 3
        with self.assertRaisesRegex(corpus.CorpusError, "schema 4 or newer"):
            corpus.validate(value)

    def test_rejects_any_attempt_to_promote_a_production_metric(self) -> None:
        value = manifest()
        value["production_promotions"] = 1
        with self.assertRaisesRegex(corpus.CorpusError, "cannot promote"):
            corpus.validate(value)

    def test_rejects_missing_held_out_evidence_for_a_target(self) -> None:
        value = manifest()
        value["participants"][1]["labels"] = [entry for entry in value["participants"][1]["labels"] if entry["gap"] != "GAP-12"]
        with self.assertRaisesRegex(corpus.CorpusError, "GAP-12 requires both"):
            corpus.validate(value)

    def test_admits_concurrent_labels_for_distinct_targets(self) -> None:
        value = manifest()
        for entry in value["participants"]:
            entry["labels"][1]["start_rel"] = 0
            entry["labels"][1]["end_rel"] = 60
            entry["labels"][2]["start_rel"] = 0
            entry["labels"][2]["end_rel"] = 60
        result = corpus.validate(value)
        self.assertEqual(result["status"], "admitted_for_external_evaluation_only")

    def test_rejects_overlap_within_one_target_series(self) -> None:
        value = manifest()
        duplicate = label("GAP-10", 30)
        value["participants"][0]["labels"].append(duplicate)
        with self.assertRaisesRegex(corpus.CorpusError, "same target series"):
            corpus.validate(value)

    def test_admits_temperature_and_spo2_pairs_at_the_same_time(self) -> None:
        value = manifest()
        for entry in value["participants"]:
            pair = label("GAP-14", 210)
            pair["signal"] = "skin_temperature"
            entry["labels"].append(pair)
        result = corpus.validate(value)
        self.assertEqual(result["labels_by_target"]["GAP-14"], 4)


if __name__ == "__main__":
    unittest.main()
