"""Offline tests for the cross-platform release version gate."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-release-version.py"
SPEC = importlib.util.spec_from_file_location("check_release_version", SCRIPT)
assert SPEC and SPEC.loader
version_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(version_gate)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        files = {
            "packages/vpn-core/Cargo.toml": '[package]\nname = "core"\nversion = "0.6.5"\n',
            "apps/macos-native/script/build_and_run.sh": (
                "{'CFBundleShortVersionString':'0.6.5','CFBundleVersion':'8'}\n"
            ),
            "apps/windows/Qingzhou/Qingzhou.csproj": "<Version>0.6.5</Version>\n",
            "apps/iphone/SplitVpn.xcodeproj/project.pbxproj": (
                "MARKETING_VERSION = 0.6.5;\nMARKETING_VERSION = 0.6.5;\n"
            ),
            "apps/android/app/build.gradle.kts": 'versionName = "0.6.5"\n',
        }
        for name, content in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)

    def tearDown(self):
        self.temporary.cleanup()

    def test_matching_platform_versions_and_tag_pass(self):
        version, platforms = version_gate.check_versions(self.root, "v0.6.5")
        self.assertEqual(version, "0.6.5")
        self.assertEqual(set(platforms.values()), {"0.6.5"})

    def test_platform_mismatch_reports_every_value(self):
        path = self.root / "apps/windows/Qingzhou/Qingzhou.csproj"
        path.write_text("<Version>0.6.4</Version>\n")
        with self.assertRaisesRegex(version_gate.VersionError, "windows=0.6.4"):
            version_gate.check_versions(self.root)

    def test_ambiguous_platform_field_is_rejected(self):
        path = self.root / "apps/iphone/SplitVpn.xcodeproj/project.pbxproj"
        path.write_text("MARKETING_VERSION = 0.6.5;\nMARKETING_VERSION = 0.6.6;\n")
        with self.assertRaisesRegex(version_gate.VersionError, "iOS 版本字段必须唯一"):
            version_gate.check_versions(self.root)

    def test_invalid_or_mismatched_tag_is_rejected(self):
        for tag, message in [("0.6.5", "vX.Y.Z"), ("v0.6.4", "不一致")]:
            with self.subTest(tag=tag), self.assertRaisesRegex(version_gate.VersionError, message):
                version_gate.check_versions(self.root, tag)

    def test_cli_can_print_only_the_version(self):
        self.assertEqual(version_gate.main(["--root", str(self.root), "--print-version"]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
