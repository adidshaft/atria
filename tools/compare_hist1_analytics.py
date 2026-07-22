#!/usr/bin/env python3
"""Compare pre/post HIST-1 analytics and recovered-publication evidence."""

from __future__ import annotations

import argparse
import re
from datetime import datetime, timezone
from pathlib import Path


SHA256_RE = re.compile(r"[0-9a-f]{64}")
PROJECTION_RE = re.compile(r"recovered_projection status=applied .*?generation=(\d+)")
DERIVED_RE = re.compile(
    r"recovered_derived status=(published|failed|superseded) generation=(\d+) archive_revision=(\d+)"
)
WIDGET_RE = re.compile(r"widget_snapshot status=ok reason=\S*?_r(\d+)(?:\s|$)")


def parse_key_values(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in raw:
            key, value = raw.strip().split("=", 1)
            fields[key] = value
    return fields


def integer(fields: dict[str, str], key: str) -> int | None:
    try:
        return int(fields[key])
    except (KeyError, ValueError):
        return None


def parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError(f"{value!r} must include a timezone offset")
    return parsed.astimezone(timezone.utc)


def valid_revision(value: str | None) -> bool:
    return value == "missing" or bool(value and SHA256_RE.fullmatch(value))


def reported_window_overlaps_gap(
    fields: dict[str, str], start_key: str, end_key: str, gap_start: str, reconnect: str
) -> bool:
    try:
        start = parse_time(fields[start_key])
        end = parse_time(fields[end_key])
        return start < parse_time(reconnect) and end > parse_time(gap_start)
    except (KeyError, ValueError):
        return False


def compare(args: argparse.Namespace) -> tuple[list[str], dict[str, object]]:
    blockers: list[str] = []
    pre = parse_key_values(args.pre_pull_summary)
    post = parse_key_values(args.post_pull_summary)
    log = args.recovery_log.read_text(encoding="utf-8", errors="replace")

    for side, fields in (("pre", pre), ("post", post)):
        if fields.get("app_provenance_status") != "pass":
            blockers.append(f"{side}_app_provenance_not_verified")
    for key in ("app_provenance_sha256", "app_binary_sha256", "app_source_fingerprint",
                "app_source_dirty_fingerprint"):
        pre_value = pre.get(key)
        post_value = post.get(key)
        if not pre_value or not post_value or pre_value != post_value:
            blockers.append(f"pre_post_{key}_mismatch")

    pre_revision = integer(pre, "recovered_projection_evidence_revision")
    post_revision = integer(post, "recovered_projection_evidence_revision")
    if pre_revision is None or post_revision is None:
        blockers.append("missing_recovered_projection_evidence_revision")
    elif post_revision <= pre_revision:
        blockers.append("recovered_projection_evidence_revision_not_advanced")
    if pre.get("recovered_projection_evidence_fingerprint") == post.get("recovered_projection_evidence_fingerprint"):
        blockers.append("recovered_projection_evidence_fingerprint_stale")

    projections = [(int(match.group(1)), match.start()) for match in PROJECTION_RE.finditer(log)]
    derived = [
        (match.group(1), int(match.group(2)), int(match.group(3)), match.start())
        for match in DERIVED_RE.finditer(log)
    ]
    published = [event for event in derived if event[0] == "published"]
    if not published:
        blockers.append("missing_recovered_derived_publication")
        published_generation = 0
        archive_revision = 0
        publication_position = -1
    else:
        _, published_generation, archive_revision, publication_position = published[-1]
        observed_generations = [generation for generation, _ in projections]
        observed_generations.extend(generation for _, generation, _, _ in derived)
        if observed_generations and published_generation != max(observed_generations):
            blockers.append("recovered_derived_publication_stale_generation")
        if not any(generation == published_generation and position < publication_position
                   for generation, position in projections):
            blockers.append("recovered_projection_generation_not_published")
        if any(generation == published_generation and position > publication_position
               for status, generation, _, position in derived if status != "published"):
            blockers.append("recovered_publication_invalidated")

    count_keys = {
        "confirmed_sleep_records": "sleep_projection_count_regressed",
        "confirmed_workouts_count": "workout_projection_count_regressed",
        "strain_projection_artifact_days": "strain_projection_days_regressed",
    }
    for key, blocker in count_keys.items():
        before = integer(pre, key)
        after = integer(post, key)
        if before is not None and after is not None and after < before:
            blockers.append(blocker)

    revision_keys = (
        "sleep_projection_artifact_revision",
        "workout_projection_artifact_revision",
        "strain_projection_artifact_revision",
        "widget_projection_artifact_revision",
    )
    for key in revision_keys:
        before = pre.get(key, "missing")
        after = post.get(key, "missing")
        if not valid_revision(after):
            blockers.append(f"invalid_{key}")
        if before != "missing" and after == "missing":
            blockers.append(f"{key}_disappeared")

    for count_key, revision_key in (
        ("confirmed_sleep_records", "sleep_projection_artifact_revision"),
        ("confirmed_workouts_count", "workout_projection_artifact_revision"),
        ("strain_projection_artifact_days", "strain_projection_artifact_revision"),
    ):
        if (integer(post, count_key) or 0) > 0 and not SHA256_RE.fullmatch(post.get(revision_key, "")):
            blockers.append(f"{revision_key}_missing_for_reported_output")

    for label, start_key, end_key, revision_key in (
        ("sleep", "latest_confirmed_sleep_start", "latest_confirmed_sleep_end",
         "sleep_projection_artifact_revision"),
        ("workout", "latest_confirmed_workout_start", "latest_confirmed_workout_end",
         "workout_projection_artifact_revision"),
    ):
        if reported_window_overlaps_gap(post, start_key, end_key, args.gap_start, args.reconnect):
            if pre.get(revision_key) == post.get(revision_key):
                blockers.append(f"{label}_projection_artifact_revision_stale_for_gap_overlap")

    widget_applicable = (
        post.get("widget_projection_status") == "ok"
        and post.get("widget_projection_app_group_enabled") == "1"
        and post.get("widget_projection_target_present") == "1"
    )
    widget_revisions = [int(match.group(1)) for match in WIDGET_RE.finditer(log)]
    if widget_applicable:
        if archive_revision <= 0 or archive_revision not in widget_revisions:
            blockers.append("widget_publication_revision_stale_or_missing")
        try:
            post_widget_time = parse_time(post["widget_projection_created_at"])
        except (KeyError, ValueError):
            post_widget_time = None
            blockers.append("widget_publication_timestamp_invalid")
        if post_widget_time is not None and post_widget_time < parse_time(args.reconnect):
            blockers.append("widget_publication_predates_reconnect")
        pre_created = pre.get("widget_projection_created_at")
        if pre_created and pre_created != "missing" and post_widget_time is not None:
            try:
                if post_widget_time <= parse_time(pre_created):
                    blockers.append("widget_publication_not_advanced")
            except ValueError:
                blockers.append("pre_widget_publication_timestamp_invalid")

    details: dict[str, object] = {
        "pre_projection_evidence_revision": pre_revision if pre_revision is not None else "missing",
        "post_projection_evidence_revision": post_revision if post_revision is not None else "missing",
        "recovered_projection_generation": published_generation,
        "recovered_derived_archive_revision": archive_revision,
        "widget_publication_applicable": 1 if widget_applicable else 0,
        "widget_publication_revisions": ",".join(map(str, widget_revisions)) if widget_revisions else "none",
    }
    return blockers, details


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pre-pull-summary", required=True, type=Path)
    parser.add_argument("--post-pull-summary", required=True, type=Path)
    parser.add_argument("--recovery-log", required=True, type=Path)
    parser.add_argument("--reconnect", required=True)
    parser.add_argument("--gap-start", required=True)
    args = parser.parse_args()
    for path in (args.pre_pull_summary, args.post_pull_summary, args.recovery_log):
        if not path.is_file():
            parser.error(f"missing evidence file: {path}")
    try:
        blockers, details = compare(args)
    except ValueError as error:
        parser.error(str(error))
    print(f"hist1_analytics_comparison_status={'pass' if not blockers else 'fail'}")
    print(f"pre_pull_summary={args.pre_pull_summary}")
    print(f"post_pull_summary={args.post_pull_summary}")
    print(f"recovery_log={args.recovery_log}")
    for key, value in details.items():
        print(f"{key}={value}")
    print("analytics_blockers=" + (",".join(blockers) if blockers else "none"))
    return 0 if not blockers else 1


if __name__ == "__main__":
    raise SystemExit(main())
