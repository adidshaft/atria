import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
TOOL = ROOT / "tools" / "app_build_provenance.py"


class AppBuildProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "test@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "Test"], check=True)
        source_dir = self.root / "Atria"
        source_dir.mkdir()
        self.source = source_dir / "App.swift"
        self.source.write_text("let version = 1\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.root), "add", "Atria/App.swift"], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "base"], check=True)
        self.source.write_text("let version = 2\n", encoding="utf-8")

        self.app = self.root / "build" / "Atria.app"
        self.app.mkdir(parents=True)
        with (self.app / "Info.plist").open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.adidshaft.atria",
                "CFBundleShortVersionString": "1.2",
                "CFBundleVersion": "42",
                "CFBundleExecutable": "Atria",
            }, handle)
        (self.app / "Atria").write_bytes(b"signed-app-executable")
        self.base = self.root / "build-identity.json"
        self.bound = self.root / "installed-provenance.json"
        self.metadata = self.root / "installed-metadata.json"
        self.write_metadata(url="file:///device/Atria.app/")

    def tearDown(self):
        self.scratch.cleanup()

    def write_metadata(self, *, url: str) -> None:
        self.metadata.write_text(json.dumps({
            "result": {
                "deviceIdentifier": "physical-device",
                "apps": [{
                    "bundleIdentifier": "com.adidshaft.atria",
                    "version": "1.2",
                    "bundleVersion": "42",
                    "bundleContainerPath": "/device/bundle",
                    "dataContainerPath": "/device/data",
                    "url": url,
                    "appGroupIdentifiers": ["group.com.adidshaft.atria"],
                }],
            }
        }) + "\n", encoding="utf-8")

    def command(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(TOOL), *arguments],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def create_and_bind(self) -> None:
        created = self.command(
            "create", "--app", str(self.app), "--source-root", str(self.root),
            "--source-path", "Atria", "--configuration", "Release", "--output", str(self.base),
        )
        self.assertEqual(created.returncode, 0, created.stdout + created.stderr)
        bound = self.command(
            "bind-installed", "--identity", str(self.base),
            "--installed-metadata", str(self.metadata), "--output", str(self.bound),
        )
        self.assertEqual(bound.returncode, 0, bound.stdout + bound.stderr)

    def verify(self) -> subprocess.CompletedProcess[str]:
        return self.command(
            "verify", "--identity", str(self.bound), "--installed-metadata", str(self.metadata),
            "--source-root", str(self.root), "--app", str(self.app),
        )

    def verify_installed_only(self) -> subprocess.CompletedProcess[str]:
        return self.command(
            "verify", "--identity", str(self.bound), "--installed-metadata", str(self.metadata),
            "--source-root", str(self.root), "--app", str(self.app), "--installed-only",
        )

    def test_binds_binary_build_installed_url_and_dirty_source_fingerprint(self):
        self.create_and_bind()
        identity = json.loads(self.bound.read_text(encoding="utf-8"))
        self.assertEqual(identity["schema"], "atria.installed-app-provenance.v1")
        self.assertEqual(identity["build"], "42")
        self.assertTrue(identity["source_dirty"])
        self.assertEqual(len(identity["binary_sha256"]), 64)
        self.assertEqual(len(identity["source_dirty_fingerprint"]), 64)
        self.assertEqual(identity["installed"]["url"], "file:///device/Atria.app/")
        verified = self.verify()
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
        self.assertIn("app_provenance_status=pass", verified.stdout)

    def test_rejects_changed_source_binary_and_reinstalled_bundle_url(self):
        self.create_and_bind()
        self.source.write_text("let version = 3\n", encoding="utf-8")
        changed_source = self.verify()
        self.assertEqual(changed_source.returncode, 1)
        self.assertIn("app_provenance_source_fingerprint_mismatch", changed_source.stdout)

        self.source.write_text("let version = 2\n", encoding="utf-8")
        (self.app / "Atria").write_bytes(b"different-executable")
        changed_binary = self.verify()
        self.assertEqual(changed_binary.returncode, 1)
        self.assertIn("app_provenance_binary_sha256_mismatch", changed_binary.stdout)

        (self.app / "Atria").write_bytes(b"signed-app-executable")
        self.write_metadata(url="file:///device/reinstalled/Atria.app/")
        reinstalled = self.verify()
        self.assertEqual(reinstalled.returncode, 1)
        self.assertIn("installed_app_url_mismatch", reinstalled.stdout)

    def test_installed_only_reports_source_drift_but_still_rejects_reinstall(self):
        self.create_and_bind()
        self.source.write_text("let version = 3\n", encoding="utf-8")
        drifted = self.verify_installed_only()
        self.assertEqual(drifted.returncode, 0, drifted.stdout + drifted.stderr)
        self.assertIn("app_provenance_status=pass", drifted.stdout)
        self.assertIn("app_source_match_status=drift", drifted.stdout)
        self.assertIn("app_provenance_verification_mode=installed_only", drifted.stdout)
        self.assertIn("app_provenance_source_fingerprint_mismatch", drifted.stdout)

        self.write_metadata(url="file:///device/reinstalled/Atria.app/")
        reinstalled = self.verify_installed_only()
        self.assertEqual(reinstalled.returncode, 1)
        self.assertIn("installed_app_url_mismatch", reinstalled.stdout)


if __name__ == "__main__":
    unittest.main()
