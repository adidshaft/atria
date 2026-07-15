#!/usr/bin/env python3
"""Verify Atria's build-bound physical qualification evidence.

The report is intentionally a strict manifest, not a place for prose claims. Every
required checkpoint must name byte-verified, repository-local evidence captured from
the same installed Atria binary. Unknown schema fields and partially populated reports
fail closed so a new physical requirement cannot be silently ignored by an old tool.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
DEFAULT_REPORT = Path("docs/evidence/physical-qualification/summary.json")
ATRIA_BUNDLE_ID = "com.adidshaft.atria"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
QUALIFICATION_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}")

REPORT_KEYS = {
    "schema_version",
    "qualification_id",
    "created_at",
    "installed_app",
    "artifacts",
    "checkpoints",
}
INSTALLED_APP_KEYS = {"bundle_id", "binary_sha256", "build", "source_commit"}
ARTIFACT_KEYS = {"path", "sha256", "kind", "app_binary_sha256"}
CHECKPOINT_KEYS = {
    "id",
    "status",
    "observed_at",
    "artifact_paths",
    "observations",
    "command_pulses",
    "witnessed_pulses",
}

ARTIFACT_KINDS = {
    "app_identity",
    "pull_summary",
    "calibration_manifest",
    "holdout_manifest",
    "negative_replay",
    "fit_output",
    "route",
    "gpx",
    "screenshot",
    "screen_recording",
    "activity_evaluation",
    "event_log",
    "performance_trace",
    "other",
}

# The observations are exact sets. Adding or removing a physical acceptance item
# requires a schema/tool update rather than letting an old verifier overlook it.
REQUIRED_CHECKPOINTS: dict[str, dict[str, set[str]]] = {
    "step_calibration": {
        "observations": {"fit_pass"},
        "artifact_kinds": {"calibration_manifest", "fit_output"},
    },
    "step_holdout": {
        "observations": {"counted_positive_within_5_percent"},
        "artifact_kinds": {"holdout_manifest", "fit_output"},
    },
    "step_negatives": {
        "observations": {"all_scoreable_zero_false_steps"},
        "artifact_kinds": {"negative_replay"},
    },
    "route_pause_gpx_share_relaunch": {
        "observations": {
            "precise_route",
            "pause_gap",
            "gpx",
            "post_save_share",
            "persisted_after_relaunch",
        },
        "artifact_kinds": {"route", "gpx", "screenshot", "event_log"},
    },
    "zone_haptics": {
        "observations": {"command_order", "physical_witness"},
        "artifact_kinds": {"event_log"},
    },
    "workout_background_recovery": {
        "observations": {
            "backgrounded",
            "foreground_resumed",
            "recovered",
            "saved_after_relaunch",
        },
        "artifact_kinds": {"event_log", "pull_summary"},
    },
    "live_activity": {
        "observations": {
            "lock_screen",
            "dynamic_island",
            "pause_resume",
            "reconnect_truthful",
            "goal_crossing",
        },
        "artifact_kinds": {"screenshot", "event_log"},
    },
    "activity_crud": {
        "observations": {
            "saved",
            "edited",
            "deleted",
            "readded",
            "shareable_after_relaunch",
        },
        "artifact_kinds": {"event_log", "pull_summary"},
    },
    "journal_deep_link": {
        "observations": {
            "notification_tapped",
            "journal_opened",
            "no_black_screen",
            "responsive",
        },
        "artifact_kinds": {"screenshot", "event_log"},
    },
    "sleep_save": {
        "observations": {"saved", "activity_visible", "persisted_after_relaunch"},
        "artifact_kinds": {"event_log", "pull_summary"},
    },
    "battery_charging_reconnect": {
        "observations": {
            "percentage",
            "charging_bolt",
            "low_state",
            "reconnect",
            "freshness_coherent",
        },
        "artifact_kinds": {"pull_summary", "screenshot", "event_log"},
    },
    "responsiveness": {
        "observations": {"settings_open", "app_switch", "scroll", "no_hang"},
        "artifact_kinds": {"screen_recording", "performance_trace"},
    },
}

HAPTIC_ORDER = [1, 3, 2, 1]


class DuplicateJSONKeyError(ValueError):
    pass


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(key)
        result[key] = value
    return result


def _is_int(value: object) -> bool:
    """JSON booleans are Python ints; physical counters must reject them."""
    return type(value) is int


def _strict_object(value: object, keys: set[str], label: str, blockers: list[str]) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        blockers.append(f"{label}_not_object")
        return None
    actual = set(value)
    for missing in sorted(keys - actual):
        blockers.append(f"{label}_missing_{missing}")
    for unknown in sorted(actual - keys):
        blockers.append(f"{label}_unknown_{unknown}")
    return value


def _utc_timestamp(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.endswith("Z"):
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() != timezone.utc.utcoffset(parsed):
        return None
    return parsed


def _regular_repo_file(repo: Path, relative: object) -> tuple[Path | None, str | None]:
    if not isinstance(relative, str) or not relative or "\x00" in relative:
        return None, "invalid_path"
    candidate = Path(relative)
    if candidate.is_absolute() or candidate != Path(*candidate.parts) or ".." in candidate.parts:
        return None, "unsafe_path"
    resolved_repo = repo.resolve()
    unresolved = resolved_repo / candidate
    cursor = resolved_repo
    for component in candidate.parts:
        cursor = cursor / component
        if cursor.is_symlink():
            return None, "symlink_path"
    resolved = unresolved.resolve()
    try:
        resolved.relative_to(resolved_repo)
    except ValueError:
        return None, "outside_repo"
    if not resolved.is_file():
        return None, "missing_regular_file"
    if resolved.stat().st_size <= 0:
        return None, "empty_file"
    return resolved, None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _string_list(value: object, label: str, blockers: list[str]) -> list[str] | None:
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        blockers.append(f"{label}_invalid")
        return None
    if len(value) != len(set(value)):
        blockers.append(f"{label}_duplicate")
    return value


def _pulse_list(value: object, label: str, blockers: list[str]) -> list[int] | None:
    if not isinstance(value, list) or any(not _is_int(item) for item in value):
        blockers.append(f"{label}_invalid")
        return None
    return value


def _verify_identity_artifact(path: Path, installed_app: dict[str, Any], blockers: list[str]) -> None:
    try:
        identity = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except DuplicateJSONKeyError:
        blockers.append("app_identity_duplicate_json_key")
        return
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        blockers.append("app_identity_invalid_json")
        return
    parsed = _strict_object(identity, INSTALLED_APP_KEYS, "app_identity", blockers)
    if parsed is None:
        return
    for key in sorted(INSTALLED_APP_KEYS):
        if parsed.get(key) != installed_app.get(key):
            blockers.append(f"app_identity_mismatch_{key}")


def verify_report(
    repo: Path,
    report_path: Path,
    *,
    expected_binary_sha256: str | None = None,
) -> dict[str, object]:
    repo = repo.resolve()
    report_path = report_path if report_path.is_absolute() else repo / report_path
    blockers: list[str] = []
    try:
        raw = json.loads(
            report_path.read_text(encoding="utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except FileNotFoundError:
        return {
            "status": "missing",
            "summary": str(report_path),
            "blockers": ["missing_physical_qualification_summary"],
        }
    except DuplicateJSONKeyError:
        return {
            "status": "fail",
            "summary": str(report_path),
            "blockers": ["duplicate_physical_qualification_json_key"],
        }
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {
            "status": "fail",
            "summary": str(report_path),
            "blockers": ["invalid_physical_qualification_json"],
        }

    report = _strict_object(raw, REPORT_KEYS, "report", blockers)
    if report is None:
        return {"status": "fail", "summary": str(report_path), "blockers": sorted(set(blockers))}

    version = report.get("schema_version")
    if not _is_int(version) or version != SCHEMA_VERSION:
        blockers.append("unsupported_schema_version")
    qualification_id = report.get("qualification_id")
    if not isinstance(qualification_id, str) or not QUALIFICATION_ID_RE.fullmatch(qualification_id):
        blockers.append("invalid_qualification_id")
    created_at = _utc_timestamp(report.get("created_at"))
    if created_at is None:
        blockers.append("invalid_created_at")

    installed_app = _strict_object(report.get("installed_app"), INSTALLED_APP_KEYS, "installed_app", blockers)
    binary_sha = ""
    if installed_app is not None:
        if installed_app.get("bundle_id") != ATRIA_BUNDLE_ID:
            blockers.append("installed_app_bundle_mismatch")
        candidate_sha = installed_app.get("binary_sha256")
        if not isinstance(candidate_sha, str) or not SHA256_RE.fullmatch(candidate_sha):
            blockers.append("invalid_installed_app_binary_sha256")
        else:
            binary_sha = candidate_sha
        build = installed_app.get("build")
        if not isinstance(build, str) or not build.strip() or len(build) > 200:
            blockers.append("invalid_installed_app_build")
        source_commit = installed_app.get("source_commit")
        if not isinstance(source_commit, str) or not COMMIT_RE.fullmatch(source_commit):
            blockers.append("invalid_installed_app_source_commit")
    if expected_binary_sha256 is not None:
        if not SHA256_RE.fullmatch(expected_binary_sha256):
            blockers.append("invalid_expected_binary_sha256")
        elif binary_sha and binary_sha != expected_binary_sha256:
            blockers.append("installed_app_binary_mismatch")

    raw_artifacts = report.get("artifacts")
    artifacts_by_path: dict[str, dict[str, Any]] = {}
    resolved_by_path: dict[str, Path] = {}
    artifact_digests: set[str] = set()
    identity_paths: list[str] = []
    if not isinstance(raw_artifacts, list) or not raw_artifacts:
        blockers.append("artifacts_invalid")
        raw_artifacts = []
    for index, raw_artifact in enumerate(raw_artifacts):
        label = f"artifact_{index}"
        artifact = _strict_object(raw_artifact, ARTIFACT_KEYS, label, blockers)
        if artifact is None:
            continue
        relative = artifact.get("path")
        if not isinstance(relative, str) or not relative:
            blockers.append(f"{label}_invalid_path")
            continue
        if relative in artifacts_by_path:
            blockers.append("duplicate_artifact_path")
            continue
        artifacts_by_path[relative] = artifact
        digest = artifact.get("sha256")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            blockers.append(f"{label}_invalid_sha256")
        elif digest in artifact_digests:
            blockers.append("duplicate_artifact_digest")
        else:
            artifact_digests.add(digest)
        kind = artifact.get("kind")
        if kind not in ARTIFACT_KINDS:
            blockers.append(f"{label}_unknown_kind")
        elif kind == "app_identity":
            identity_paths.append(relative)
        if artifact.get("app_binary_sha256") != binary_sha:
            blockers.append(f"{label}_app_binary_mismatch")
        resolved, path_error = _regular_repo_file(repo, relative)
        if path_error:
            blockers.append(f"{label}_{path_error}")
        elif resolved is not None:
            resolved_by_path[relative] = resolved
            if isinstance(digest, str) and SHA256_RE.fullmatch(digest) and _sha256(resolved) != digest:
                blockers.append(f"{label}_digest_mismatch")

    if len(identity_paths) != 1:
        blockers.append("app_identity_artifact_count")
    elif installed_app is not None and identity_paths[0] in resolved_by_path:
        _verify_identity_artifact(resolved_by_path[identity_paths[0]], installed_app, blockers)

    raw_checkpoints = report.get("checkpoints")
    checkpoints_by_id: dict[str, dict[str, Any]] = {}
    used_artifacts: set[str] = set()
    observed_dates: list[datetime] = []
    if not isinstance(raw_checkpoints, list):
        blockers.append("checkpoints_invalid")
        raw_checkpoints = []
    for index, raw_checkpoint in enumerate(raw_checkpoints):
        label = f"checkpoint_{index}"
        checkpoint = _strict_object(raw_checkpoint, CHECKPOINT_KEYS, label, blockers)
        if checkpoint is None:
            continue
        checkpoint_id = checkpoint.get("id")
        if not isinstance(checkpoint_id, str) or checkpoint_id not in REQUIRED_CHECKPOINTS:
            blockers.append(f"{label}_unknown_id")
            continue
        if checkpoint_id in checkpoints_by_id:
            blockers.append("duplicate_checkpoint_id")
            continue
        checkpoints_by_id[checkpoint_id] = checkpoint
        if checkpoint.get("status") != "pass":
            blockers.append(f"checkpoint_{checkpoint_id}_not_pass")
        observed_at = _utc_timestamp(checkpoint.get("observed_at"))
        if observed_at is None:
            blockers.append(f"checkpoint_{checkpoint_id}_invalid_observed_at")
        else:
            observed_dates.append(observed_at)
        paths = _string_list(checkpoint.get("artifact_paths"), f"checkpoint_{checkpoint_id}_artifact_paths", blockers)
        if paths is not None:
            if not paths:
                blockers.append(f"checkpoint_{checkpoint_id}_artifacts_empty")
            kinds: set[str] = set()
            for path in paths:
                artifact = artifacts_by_path.get(path)
                if artifact is None:
                    blockers.append(f"checkpoint_{checkpoint_id}_unhashed_artifact")
                else:
                    used_artifacts.add(path)
                    kind = artifact.get("kind")
                    if isinstance(kind, str):
                        kinds.add(kind)
            missing_kinds = REQUIRED_CHECKPOINTS[checkpoint_id]["artifact_kinds"] - kinds
            for kind in sorted(missing_kinds):
                blockers.append(f"checkpoint_{checkpoint_id}_missing_{kind}")
        observations = _string_list(
            checkpoint.get("observations"),
            f"checkpoint_{checkpoint_id}_observations",
            blockers,
        )
        if observations is not None and set(observations) != REQUIRED_CHECKPOINTS[checkpoint_id]["observations"]:
            blockers.append(f"checkpoint_{checkpoint_id}_observations_mismatch")
        command_pulses = _pulse_list(
            checkpoint.get("command_pulses"),
            f"checkpoint_{checkpoint_id}_command_pulses",
            blockers,
        )
        witnessed_pulses = _pulse_list(
            checkpoint.get("witnessed_pulses"),
            f"checkpoint_{checkpoint_id}_witnessed_pulses",
            blockers,
        )
        expected_pulses = HAPTIC_ORDER if checkpoint_id == "zone_haptics" else []
        if command_pulses is not None and command_pulses != expected_pulses:
            blockers.append(f"checkpoint_{checkpoint_id}_command_pulses_mismatch")
        if witnessed_pulses is not None and witnessed_pulses != expected_pulses:
            blockers.append(f"checkpoint_{checkpoint_id}_witnessed_pulses_mismatch")

    for checkpoint_id in sorted(set(REQUIRED_CHECKPOINTS) - set(checkpoints_by_id)):
        blockers.append(f"missing_checkpoint_{checkpoint_id}")
    for unused in sorted(set(artifacts_by_path) - used_artifacts - set(identity_paths)):
        blockers.append(f"unused_artifact_{unused}")
    if created_at is not None and any(observed > created_at for observed in observed_dates):
        blockers.append("checkpoint_observed_after_report_created")

    unique_blockers = sorted(set(blockers))
    return {
        "status": "pass" if not unique_blockers else "fail",
        "summary": str(report_path),
        "blockers": unique_blockers,
        "schema_version": version if _is_int(version) else "invalid",
        "qualification_id": qualification_id if isinstance(qualification_id, str) else "missing",
        "binary_sha256": binary_sha or "missing",
        "artifact_count": len(artifacts_by_path),
        "checkpoint_count": len(checkpoints_by_id),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", nargs="?", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--expected-binary-sha256")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    result = verify_report(
        args.repo,
        args.report,
        expected_binary_sha256=args.expected_binary_sha256,
    )
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(
            "ATRIA_PHYSICAL_QUALIFICATION "
            f"status={result['status']} "
            f"qualification_id={result.get('qualification_id', 'missing')} "
            f"binary_sha256={result.get('binary_sha256', 'missing')} "
            f"artifacts={result.get('artifact_count', 0)} "
            f"checkpoints={result.get('checkpoint_count', 0)} "
            f"blockers={','.join(result.get('blockers', [])) or 'none'} "
            f"summary={result['summary']}"
        )
    return 0 if result["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
