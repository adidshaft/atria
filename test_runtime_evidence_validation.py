import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "validate_runtime_evidence",
    ROOT / "tools" / "validate_runtime_evidence.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


POINT = {
    "latitude": 28.6139,
    "longitude": 77.2090,
    "altitude": 220.0,
    "timestamp": "2026-07-15T12:00:01Z",
    "horizontalAccuracy": 4.0,
    "verticalAccuracy": 6.0,
    "startsNewSegment": True,
}


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + "\n", encoding="utf-8")


def populate_valid(root: Path) -> None:
    write_json(
        root / "pending-workout-intent-v1.json",
        {
            "startedAt": 805_000_000.0,
            "endedAt": None,
            "activityType": "walk",
            "strengthSets": [],
            "excludedIntervals": [],
            "startingStepCount": 100,
            "pausedStepCount": 0,
            "stepAccountingIsComplete": True,
            "startingDayStrain": 1.2,
            "persistenceRevision": 3,
        },
    )
    write_json(
        root / "active-workout-route.json",
        {
            "schema": 1,
            "activityType": "walk",
            "startedAt": "2026-07-15T12:00:00Z",
            "finalizedAt": None,
            "points": [],
            "distanceMeters": 12.0,
            "elevationGainMeters": 1.0,
            "pauseStartedAt": None,
            "accumulatedPauseDuration": 0.0,
            "updatedAt": "2026-07-15T12:00:02Z",
            "persistedPointCount": 1,
            "journalByteCount": 128,
        },
    )
    (root / "active-workout-route.points.ndjson").write_text(
        json.dumps(POINT) + "\n",
        encoding="utf-8",
    )
    write_json(
        root / "pending-workout-route-transaction.json",
        {
            "schema": 1,
            "operation": "edit",
            "oldWorkoutID": "workout-old",
            "createdAt": "2026-07-15T12:00:03Z",
        },
    )
    write_json(
        root / "atria-strap-step-ledger.json",
        {
            "schema": 1,
            "segmentID": "A7F01BB5-46CA-448C-B7E0-E1D58D793D49",
            "segmentStartedAt": 805_000_000.0,
            "updatedAt": 805_000_004.0,
            "segmentSteps": 23,
            "segmentRawSteps": 21,
            "cumulativeSteps": 123,
            "cumulativeRawSteps": 121,
            "deviceTimestamp": 1_784_000_000,
            "state": "confirmed",
        },
    )
    write_json(
        root / "atria-workout-routes" / "route-1.json",
        {
            "id": "route-1",
            "workoutID": "workout-1",
            "activityType": "walk",
            "startedAt": "2026-07-15T12:00:00Z",
            "endedAt": "2026-07-15T12:01:40Z",
            "points": [POINT],
            "distanceMeters": 100.0,
            "elevationGainMeters": 2.0,
        },
    )


class RuntimeEvidenceValidationTests(unittest.TestCase):
    def test_complete_authority_bundle_is_strictly_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            populate_valid(root)
            result = MODULE.validate_runtime_state(root)

        self.assertEqual(result["runtime_evidence_validation_status"], "ok")
        self.assertEqual(result["runtime_evidence_present_artifacts"], "6")
        self.assertEqual(result["runtime_evidence_invalid_artifacts"], "0")
        self.assertEqual(result["runtime_active_route_point_count_consistency"], "ok")
        self.assertEqual(result["runtime_saved_workout_route_count"], "1")

    def test_missing_optional_authorities_are_explicit_not_invented(self):
        with tempfile.TemporaryDirectory() as directory:
            result = MODULE.validate_runtime_state(Path(directory))

        self.assertEqual(result["runtime_evidence_validation_status"], "empty")
        self.assertEqual(result["runtime_evidence_present_artifacts"], "0")
        self.assertTrue(
            all(
                value == "missing"
                for key, value in result.items()
                if key.endswith("_validation")
            )
        )

    def test_boolean_counts_coordinates_and_route_journal_mismatch_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            populate_valid(root)
            ledger = json.loads((root / "atria-strap-step-ledger.json").read_text())
            ledger["cumulativeSteps"] = True
            write_json(root / "atria-strap-step-ledger.json", ledger)
            route = json.loads((root / "atria-workout-routes" / "route-1.json").read_text())
            route["points"][0]["latitude"] = 91
            write_json(root / "atria-workout-routes" / "route-1.json", route)
            (root / "active-workout-route.points.ndjson").write_text(
                json.dumps(POINT) + "\n" + json.dumps({**POINT, "timestamp": "2026-07-15T12:00:02Z"}) + "\n",
                encoding="utf-8",
            )
            result = MODULE.validate_runtime_state(root)

        self.assertEqual(result["runtime_evidence_validation_status"], "invalid")
        self.assertEqual(result["runtime_strap_step_ledger_validation"], "invalid")
        self.assertEqual(result["runtime_saved_workout_routes_validation"], "invalid")
        self.assertEqual(result["runtime_active_route_point_count_consistency"], "invalid")
        self.assertEqual(result["runtime_evidence_invalid_artifacts"], "3")

    def test_duplicate_saved_workout_identity_and_unknown_file_type_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            populate_valid(root)
            original = json.loads((root / "atria-workout-routes" / "route-1.json").read_text())
            duplicate = dict(original)
            duplicate["id"] = "route-2"
            write_json(root / "atria-workout-routes" / "route-2.json", duplicate)
            (root / "atria-workout-routes" / "unexpected.gpx").write_text("<gpx/>")
            result = MODULE.validate_runtime_state(root)

        self.assertEqual(result["runtime_saved_workout_routes_validation"], "invalid")
        self.assertEqual(result["runtime_evidence_validation_status"], "invalid")


if __name__ == "__main__":
    unittest.main()
