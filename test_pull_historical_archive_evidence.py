import json
import os
import plistlib
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PULL = ROOT / "pull_atria_state.sh"
PROVENANCE = ROOT / "tools" / "app_build_provenance.py"
VALIDATED_LAYOUT = "whoop4_0x2f_openstrap_v1_v24"
APPLE_EPOCH_OFFSET = 978_307_200


def active_journal_segment(
    sequence,
    sample_start,
    rr_start,
    *,
    journal_id="11111111-2222-3333-4444-555555555555",
    sample_count=1,
    rr_count=1,
    updated_at=None,
):
    updated_at = updated_at if updated_at is not None else time.time() - APPLE_EPOCH_OFFSET
    return {
        "schema": 2,
        "sequence": sequence,
        "id": journal_id,
        "label": "All-day wear",
        "startedAt": updated_at - 30,
        "updatedAt": updated_at,
        "sampleStartIndex": sample_start,
        "samples": [
            {"t": updated_at - sample_count + index, "bpm": 70 + index}
            for index in range(sample_count)
        ],
        "rrSampleStartIndex": rr_start,
        "rrSamples": [
            {"t": updated_at - rr_count + index, "ms": 800 + index, "source": "standardHeartRateMeasurement2A37"}
            for index in range(rr_count)
        ],
        "rawHRNotifications": sample_start + sample_count,
        "acceptedHRSamples": sample_start + sample_count,
        "zeroHRSamples": 0,
        "heldArtifacts": 0,
        "droppedArtifacts": 0,
        "rawHRGaps": 0,
        "acceptedHRGaps": 0,
        "maxRawHRGap": 1,
        "maxAcceptedHRGap": 1,
    }


def run_runtime_journal_pull(root, segments, *, simulate_partial_segment_copy=False):
    device = root / "device"
    segment_directory = device / "Documents" / "atria-active-session.segments"
    segment_directory.mkdir(parents=True)
    for filename, payload in segments.items():
        target = segment_directory / filename
        if isinstance(payload, str):
            target.write_text(payload, encoding="utf-8")
        else:
            target.write_text(json.dumps(payload), encoding="utf-8")

    fake = root / "fake-devicectl"
    fake.write_text(
        """#!/bin/sh
set -eu
root=${FAKE_DEVICE_ROOT:?}
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = processes ]; then
  printf 'Atria com.adidshaft.atria\\n'
  exit 0
fi
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = apps ]; then
  output=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json-output) output=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '{"result":{"deviceIdentifier":"fake-device","apps":[]}}\\n' > "$output"
  exit 0
fi
if [ "$1" = device ] && [ "$2" = copy ] && [ "$3" = from ]; then
  shift 3
  source_path=
  destination_path=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_path=$2; shift 2 ;;
      --destination) destination_path=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  source_path="$root/$source_path"
  [ -e "$source_path" ] || exit 1
  mkdir -p "$(dirname "$destination_path")"
  if [ "${FAKE_PARTIAL_SEGMENT_COPY:-0}" = 1 ] && [ "$(basename "$source_path")" = atria-active-session.segments ]; then
    mkdir -p "$destination_path"
    first_file=$(find "$source_path" -type f -name '*.json' -print -quit)
    [ -n "$first_file" ] && cp "$first_file" "$destination_path/"
    exit 1
  fi
  cp -R "$source_path" "$destination_path"
  exit 0
fi
exit 2
""",
        encoding="utf-8",
    )
    fake.chmod(0o755)
    evidence = root / "evidence"
    environment = os.environ.copy()
    environment.update(
        ATRIA_DEVICETCL=str(fake),
        FAKE_DEVICE_ROOT=str(device),
        FAKE_PARTIAL_SEGMENT_COPY="1" if simulate_partial_segment_copy else "0",
    )
    result = subprocess.run(
        [str(PULL), "--device", "fake-device", "--runtime-only", "--evidence-dir", str(evidence)],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise AssertionError(result.stdout + result.stderr)
    return (evidence / "pull-summary.txt").read_text(encoding="utf-8")


class PullHistoricalArchiveEvidenceTests(unittest.TestCase):
    def test_runtime_pull_accepts_only_complete_fresh_segment_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            first = active_journal_segment(7, 0, 0, sample_count=2, rr_count=2)
            second = active_journal_segment(8, 2, 2, sample_count=1, rr_count=1)
            summary = run_runtime_journal_pull(
                Path(directory),
                {
                    "segment-00000007.json": first,
                    "segment-00000008.json": second,
                },
            )

        for expected in [
            "active_journal_segment_parse_status=ok",
            "active_journal_segment_id_status=ok",
            "active_journal_segment_sequence_status=ok",
            "active_journal_segment_sample_continuity_status=ok",
            "active_journal_segment_rr_continuity_status=ok",
            "active_journal_segment_reconstruction_status=ok",
            "active_journal_segment_snapshot_freshness=fresh",
            "active_journal_torn_copy_status=none",
            "active_journal_final_source=segmented_canonical",
            "active_journal_final_status=ok",
            "active_journal_samples=3",
            "active_journal_rr_values=3",
        ]:
            self.assertIn(expected, summary)

    def test_runtime_pull_rejects_malformed_segment_instead_of_certifying_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = run_runtime_journal_pull(
                Path(directory),
                {
                    "segment-00000000.json": active_journal_segment(0, 0, 0),
                    "segment-00000001.json": '{"schema":2,"sequence":1',
                },
            )

        for expected in [
            "active_journal_segment_parse_errors=1",
            "active_journal_segment_parse_status=error",
            "active_journal_segment_reconstruction_status=invalid",
            "active_journal_segment_integrity_status=malformed_segments",
            "active_journal_torn_copy_status=detected",
            "active_journal_torn_copy_reason=malformed_segments",
            "active_journal_torn_copy_freshness=fresh",
            "active_journal_final_source=invalid_segmented_canonical",
            "active_journal_final_status=invalid",
        ]:
            self.assertIn(expected, summary)
        self.assertNotIn("active_journal_final_status=ok", summary)

    def test_runtime_pull_rejects_partial_segment_directory_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = run_runtime_journal_pull(
                Path(directory),
                {"segment-00000000.json": active_journal_segment(0, 0, 0)},
                simulate_partial_segment_copy=True,
            )

        for expected in [
            "active_journal_segments_status=partial_copy",
            "active_journal_segment_reconstruction_status=invalid",
            "active_journal_segment_integrity_status=partial_directory_copy",
            "active_journal_torn_copy_status=detected",
            "active_journal_torn_copy_reason=partial_directory_copy",
            "active_journal_torn_copy_freshness=unknown",
            "active_journal_final_status=invalid",
        ]:
            self.assertIn(expected, summary)
        self.assertNotIn("active_journal_final_status=ok", summary)

    def test_runtime_pull_rejects_mixed_ids_and_all_continuity_gaps(self):
        cases = {
            "mixed_ids": (
                {
                    "segment-00000000.json": active_journal_segment(0, 0, 0),
                    "segment-00000001.json": active_journal_segment(
                        1,
                        1,
                        1,
                        journal_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                    ),
                },
                ["active_journal_segment_id_status=mixed", "active_journal_torn_copy_reason=mixed_journal_ids"],
            ),
            "sequence_gap": (
                {
                    "segment-00000000.json": active_journal_segment(0, 0, 0),
                    "segment-00000002.json": active_journal_segment(2, 1, 1),
                },
                [
                    "active_journal_segment_sequence_status=noncontiguous",
                    "active_journal_torn_copy_reason=noncontiguous_sequence",
                ],
            ),
            "sample_gap": (
                {
                    "segment-00000000.json": active_journal_segment(0, 0, 0),
                    "segment-00000001.json": active_journal_segment(1, 2, 1),
                },
                [
                    "active_journal_segment_sample_continuity_status=noncontiguous",
                    "active_journal_segment_rr_continuity_status=ok",
                    "active_journal_torn_copy_reason=sample_cursor_gap",
                ],
            ),
            "rr_gap": (
                {
                    "segment-00000000.json": active_journal_segment(0, 0, 0),
                    "segment-00000001.json": active_journal_segment(1, 1, 2),
                },
                [
                    "active_journal_segment_sample_continuity_status=ok",
                    "active_journal_segment_rr_continuity_status=noncontiguous",
                    "active_journal_torn_copy_reason=rr_cursor_gap",
                ],
            ),
        }
        for name, (segments, expected_values) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                summary = run_runtime_journal_pull(Path(directory), segments)
                for expected in expected_values + [
                    "active_journal_segment_reconstruction_status=invalid",
                    "active_journal_torn_copy_status=detected",
                    "active_journal_torn_copy_freshness=fresh",
                    "active_journal_final_status=invalid",
                ]:
                    self.assertIn(expected, summary)
                self.assertNotIn("active_journal_final_status=ok", summary)

    def test_pull_exports_identity_index_and_aggregates_base_plus_rotated_jsonl(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "device"
            archive = device / "Documents" / "atria-historical"
            segments = archive / "segments"
            segments.mkdir(parents=True)

            base_row = {
                "schema": 3,
                "source": "0x2f",
                "layoutVersion": "legacy_unvalidated_layout",
                "unix7": 1_784_000_000,
                "metricUsable": False,
                "currentSessionUsable": False,
            }
            segment_row = {
                "schema": 3,
                "source": "0x2f",
                "layoutVersion": VALIDATED_LAYOUT,
                "unix7": 1_784_000_015,
                "clockCorrectedUnix7": 1_784_000_015,
                "clockCorrectionStatus": "clock_ref_present",
                "gravityValidated": True,
                "whoofHR17": 64,
                "metricUsable": True,
                "currentSessionUsable": True,
                "_atriaHistoryKey": "gap-key",
            }
            (archive / "historical-archive.jsonl").write_text(
                json.dumps(base_row) + "\n", encoding="utf-8"
            )
            (segments / "historical-archive-2026-07-18.jsonl").write_text(
                json.dumps(segment_row) + "\n", encoding="utf-8"
            )
            (archive / "historical-archive.identity.jsonl").write_text(
                json.dumps({"version": 1, "key": "gap-key", "archivePath": "segment"}) + "\n",
                encoding="utf-8",
            )
            (archive / "historical-archive.manifest.json").write_text(
                json.dumps({
                    "activeSegmentRelativePath": (
                        "Documents/atria-historical/segments/"
                        "historical-archive-2026-07-18.jsonl"
                    ),
                    "rotationThresholdBytes": 134_217_728,
                }) + "\n",
                encoding="utf-8",
            )

            fake_app = root / "Atria.app"
            fake_app.mkdir()
            with (fake_app / "Info.plist").open("wb") as handle:
                plistlib.dump({
                    "CFBundleIdentifier": "com.adidshaft.atria",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleVersion": "1",
                    "CFBundleExecutable": "Atria",
                }, handle)
            (fake_app / "Atria").write_bytes(b"functional-pull-binary")
            installed_metadata = root / "installed-metadata.json"
            installed_metadata.write_text(json.dumps({
                "result": {
                    "deviceIdentifier": "fake-device",
                    "apps": [{
                        "bundleIdentifier": "com.adidshaft.atria",
                        "version": "1.0",
                        "bundleVersion": "1",
                        "bundleContainerPath": "/fake/bundle",
                        "dataContainerPath": "/fake/data",
                        "url": "file:///fake/bundle/Atria.app/",
                        "appGroupIdentifiers": ["group.com.adidshaft.atria"],
                    }],
                }
            }) + "\n", encoding="utf-8")
            build_identity = root / "build-identity.json"
            installed_provenance = device / "Documents" / "atria-installed-app-provenance.json"
            created = subprocess.run([
                "python3", str(PROVENANCE), "create", "--app", str(fake_app),
                "--source-root", str(ROOT), "--source-path", "Atria",
                "--configuration", "Debug", "--output", str(build_identity),
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
            bound = subprocess.run([
                "python3", str(PROVENANCE), "bind-installed", "--identity", str(build_identity),
                "--installed-metadata", str(installed_metadata), "--output", str(installed_provenance),
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(bound.returncode, 0, bound.stdout + bound.stderr)

            fake = root / "fake-devicectl"
            fake.write_text(
                """#!/bin/sh
set -eu
root=${FAKE_DEVICE_ROOT:?}
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = processes ]; then
  printf 'Atria com.adidshaft.atria\\n'
  exit 0
fi
if [ "$1" = device ] && [ "$2" = info ] && [ "$3" = apps ]; then
  output=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json-output) output=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  cp "${FAKE_INSTALLED_METADATA:?}" "$output"
  exit 0
fi
if [ "$1" = device ] && [ "$2" = copy ] && [ "$3" = from ]; then
  shift 3
  source_path=
  destination_path=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) source_path=$2; shift 2 ;;
      --destination) destination_path=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  source_path="$root/$source_path"
  [ -e "$source_path" ] || exit 1
  mkdir -p "$(dirname "$destination_path")"
  cp -R "$source_path" "$destination_path"
  exit 0
fi
exit 2
""",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            evidence = root / "evidence"
            environment = os.environ.copy()
            environment.update(
                ATRIA_DEVICETCL=str(fake),
                FAKE_DEVICE_ROOT=str(device),
                FAKE_INSTALLED_METADATA=str(installed_metadata),
            )
            result = subprocess.run(
                [str(PULL), "--device", "fake-device", "--evidence-dir", str(evidence)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            self.assertEqual(
                (evidence / "historical-archive.identity.jsonl").read_text(encoding="utf-8"),
                (archive / "historical-archive.identity.jsonl").read_text(encoding="utf-8"),
            )
            summary = (evidence / "pull-summary.txt").read_text(encoding="utf-8")
            for expected in [
                "historical_archive_identity_index_status=ok",
                "historical_archive_identity_summary_status=ok",
                "historical_archive_identity_entries=1",
                "historical_archive_identity_unique_keys=1",
                "historical_archive_identity_duplicate_keys=0",
                "historical_archive_files_scanned=2",
                "historical_archive_rows=2",
                "historical_archive_metric_usable_rows=1",
                f"historical_archive_validated_metric_layouts={VALIDATED_LAYOUT}",
                "historical_archive_metric_ready=1",
                "historical_archive_metric_promotion_blocker=none",
                "installed_app_metadata_status=ok",
                "installed_app_provenance_status=ok",
                "app_provenance_status=pass",
                "recovered_projection_evidence_revision=1",
            ]:
                self.assertIn(expected, summary)

            evidence_two = root / "evidence-two"
            second = subprocess.run(
                [str(PULL), "--device", "fake-device", "--evidence-dir", str(evidence_two)],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            second_summary = (evidence_two / "pull-summary.txt").read_text(encoding="utf-8")
            self.assertIn("historical_archive_dedup_status=hardlinked", second_summary)
            self.assertIn(
                "historical_archive_identity_index_dedup_status=hardlinked",
                second_summary,
            )
            self.assertIn(
                "historical_archive_segment_1_dedup_status=hardlinked",
                second_summary,
            )
            for relative_path in [
                Path("historical-archive.jsonl"),
                Path("historical-archive.identity.jsonl"),
                Path("historical-archive-segments/historical-archive-2026-07-18.jsonl"),
            ]:
                self.assertEqual(
                    (evidence / relative_path).stat().st_ino,
                    (evidence_two / relative_path).stat().st_ino,
                    f"{relative_path} must reuse physical storage",
                )


if __name__ == "__main__":
    unittest.main()
