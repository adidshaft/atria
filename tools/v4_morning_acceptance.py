#!/usr/bin/env python3
"""Fail-closed evidence checks for the resumable v4 physical acceptance runner."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


class AcceptanceError(ValueError):
    pass


def read_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        if key:
            values[key] = value
    return values


def require(values: dict[str, str], key: str, expected: set[str]) -> None:
    actual = values.get(key, "missing")
    if actual not in expected:
        raise AcceptanceError(f"{key}={actual!r}; required one of {sorted(expected)!r}")


def check_summary(path: Path, profile: str) -> dict[str, str]:
    if not path.is_file():
        raise AcceptanceError(f"missing pull summary: {path}")
    values = read_key_values(path)
    require(values, "process_status", {"running"})
    require(values, "process_name_status", {"atria"})
    require(values, "app_provenance_status", {"pass"})
    require(values, "active_journal_final_status", {"ok"})
    require(values, "active_journal_torn_copy_status", {"none"})
    require(values, "active_journal_continuity_status", {"active"})
    require(values, "active_journal_freshness", {"fresh"})
    if values.get("active_journal_final_source") == "segmented_canonical":
        for key in (
            "active_journal_segment_reconstruction_status",
            "active_journal_segment_integrity_status",
            "active_journal_segment_sequence_status",
            "active_journal_segment_sample_continuity_status",
            "active_journal_segment_rr_continuity_status",
        ):
            require(values, key, {"ok"})
    require(values, "runtime_evidence_validation_status", {"ok"})
    samples = values.get("active_journal_samples", "")
    if not samples.isdigit() or int(samples) <= 0:
        raise AcceptanceError(f"active_journal_samples={samples!r}; required > 0")
    if profile == "full":
        require(values, "historical_archive_summary_status", {"ok"})
        require(values, "historical_archive_identity_summary_status", {"ok"})
        for key in (
            "historical_archive_parse_errors",
            "historical_archive_identity_duplicate_keys",
            "historical_archive_identity_parse_errors",
        ):
            if values.get(key) != "0":
                raise AcceptanceError(f"{key}={values.get(key, 'missing')!r}; required '0'")
    elif profile != "runtime":
        raise AcceptanceError(f"unknown summary profile: {profile}")
    return values


def matching_app(metadata: dict[str, Any], bundle_id: str) -> dict[str, Any]:
    result = metadata.get("result")
    apps = result.get("apps") if isinstance(result, dict) else metadata.get("apps")
    if not isinstance(apps, list):
        raise AcceptanceError("installed-app metadata has no apps array")
    matches = [item for item in apps if isinstance(item, dict) and item.get("bundleIdentifier") == bundle_id]
    if len(matches) != 1:
        raise AcceptanceError(f"expected exactly one installed {bundle_id} app, found {len(matches)}")
    return matches[0]


def extract_metadata(source: Path, bundle_id: str, group_id: str) -> dict[str, Any]:
    try:
        metadata = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"invalid installed-app metadata: {error}") from error
    if not isinstance(metadata, dict):
        raise AcceptanceError("installed-app metadata is not an object")
    app = matching_app(metadata, bundle_id)
    data_path = app.get("dataContainerPath")
    bundle_path = app.get("bundleContainerPath")
    url = app.get("url")
    groups = sorted(app.get("appGroupIdentifiers") or [])
    if not isinstance(data_path, str) or not data_path:
        raise AcceptanceError("installed app has no dataContainerPath")
    if not isinstance(bundle_path, str) or not bundle_path:
        raise AcceptanceError("installed app has no bundleContainerPath")
    if not isinstance(url, str) or not url:
        raise AcceptanceError("installed app has no URL")
    if groups != [group_id]:
        raise AcceptanceError(f"app-group identifiers {groups!r} do not exactly match {[group_id]!r}")
    return {
        "bundle_id": bundle_id,
        "bundle_container_path": bundle_path,
        "data_container_path": data_path,
        "app_url": url,
        "app_group_identifiers": groups,
        "app_group_container_path": f"coredevice://appGroupDataContainer/{group_id}",
        "version": app.get("version"),
        "build": app.get("bundleVersion"),
    }


def compare_metadata(before: dict[str, Any], after: dict[str, Any]) -> None:
    for key in ("bundle_id", "data_container_path", "app_group_identifiers", "app_group_container_path"):
        if before.get(key) != after.get(key):
            raise AcceptanceError(f"in-place install changed {key}: {before.get(key)!r} -> {after.get(key)!r}")
    if (before.get("bundle_container_path") == after.get("bundle_container_path")
            and before.get("app_url") == after.get("app_url")):
        raise AcceptanceError("install did not rotate the app bundle path/URL")


SAVED_RE = re.compile(r"ATRIADBG active_session_journal status=saved .*?samples=(\d+) .*?compacted=(\d+)")
RESTORED_RE = re.compile(r"ATRIADBG active_session_journal status=restored .*?samples=(\d+)")
BOUNDARY_RE = re.compile(
    r"ATRIADBG active_session_journal status=cleared "
    r"reason=(?:long_wear_retention_roll|civil_day_boundary_rollover|long_gap_rollover)\b"
)
FAILURE_RE = re.compile(
    r"ATRIADBG active_session_journal status=save_failed\b|"
    r"next_action=verified_full_rebase\b|\bverified_full_rebase\b"
)


def scan_console(path: Path, minimum_compactions: int, minimum_restored: int) -> dict[str, int]:
    if not path.is_file():
        raise AcceptanceError(f"missing console log: {path}")
    compactions = 0
    restored_max = -1
    previous_saved: int | None = None
    boundary_since_previous = False
    saved_lines = 0
    for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        if FAILURE_RE.search(line):
            raise AcceptanceError(f"journal failure marker at console line {line_number}")
        restored = RESTORED_RE.search(line)
        if restored:
            restored_max = max(restored_max, int(restored.group(1)))
        if BOUNDARY_RE.search(line):
            boundary_since_previous = True
        saved = SAVED_RE.search(line)
        if not saved:
            continue
        samples = int(saved.group(1))
        compacted = int(saved.group(2))
        saved_lines += 1
        if previous_saved is not None and samples < previous_saved and not boundary_since_previous:
            raise AcceptanceError(
                f"journal sample-count regression at console line {line_number}: "
                f"{previous_saved} -> {samples} without a durable session boundary"
            )
        previous_saved = samples
        boundary_since_previous = False
        if compacted == 1:
            compactions += 1
    if restored_max < minimum_restored:
        raise AcceptanceError(f"restored sample count {restored_max} is below pre-install count {minimum_restored}")
    if compactions < minimum_compactions:
        raise AcceptanceError(f"only {compactions} successful journal compactions; need {minimum_compactions}")
    return {
        "journal_compactions": compactions,
        "journal_restored_samples": restored_max,
        "journal_saved_lines": saved_lines,
        "journal_latest_saved_samples": previous_saved or 0,
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(root: Path, output: Path) -> int:
    output_resolved = output.resolve()
    rows: list[str] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.resolve() == output_resolved:
            continue
        rows.append(f"{sha256_file(path)}  {path.relative_to(root)}")
    output.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")
    return len(rows)


def load_object(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise AcceptanceError(f"expected object: {path}")
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    summary = subparsers.add_parser("check-summary")
    summary.add_argument("--summary", type=Path, required=True)
    summary.add_argument("--profile", choices=("runtime", "full"), required=True)
    extract = subparsers.add_parser("extract-metadata")
    extract.add_argument("--source", type=Path, required=True)
    extract.add_argument("--bundle-id", required=True)
    extract.add_argument("--group-id", required=True)
    extract.add_argument("--output", type=Path, required=True)
    compare = subparsers.add_parser("compare-metadata")
    compare.add_argument("--before", type=Path, required=True)
    compare.add_argument("--after", type=Path, required=True)
    scan = subparsers.add_parser("scan-console")
    scan.add_argument("--console", type=Path, required=True)
    scan.add_argument("--minimum-compactions", type=int, default=2)
    scan.add_argument("--minimum-restored", type=int, required=True)
    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--root", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "check-summary":
            values = check_summary(args.summary, args.profile)
            print("summary_acceptance_status=pass")
            print(f"summary_active_journal_samples={values['active_journal_samples']}")
        elif args.command == "extract-metadata":
            value = extract_metadata(args.source, args.bundle_id, args.group_id)
            args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            print("metadata_extract_status=pass")
        elif args.command == "compare-metadata":
            compare_metadata(load_object(args.before), load_object(args.after))
            print("container_continuity_status=pass")
        elif args.command == "scan-console":
            if args.minimum_compactions < 2:
                raise AcceptanceError("minimum compactions must be at least 2")
            result = scan_console(args.console, args.minimum_compactions, args.minimum_restored)
            print("journal_monitor_status=pass")
            for key, value in result.items():
                print(f"{key}={value}")
        elif args.command == "manifest":
            count = write_manifest(args.root, args.output)
            print("evidence_manifest_status=pass")
            print(f"evidence_manifest_files={count}")
    except (AcceptanceError, OSError, json.JSONDecodeError) as error:
        print(f"acceptance_error={error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
