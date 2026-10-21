#!/usr/bin/env python3
"""Exercise the release entry point without signing or creating real disk images."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "script" / "package_dmg.sh"


class PackageConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="qingzhou-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "轻舟.app"
        resources = self.app / "Contents" / "Resources"
        resources.mkdir(parents=True)
        self.config = resources / "config.json"
        self.output = self.root / "output"
        self.output.mkdir()
        self.calls = self.root / "disk-image-calls"
        tools = self.root / "bin"
        tools.mkdir()
        # Only downstream packaging tools are stubbed; the config validator is real.
        stubs = {
            "plutil": "printf '0.4.8\\n'",
            "lipo": "printf 'arm64\\n'",
            "codesign": "if [ \"$1\" = '-dvv' ]; then printf 'Authority=Developer ID Application: Fixture\\n' >&2; fi",
            "hdiutil": 'printf "%s\\n" "$1" >> "$PACKAGE_TEST_CALLS"\nif [ "$1" = create ]; then for last; do :; done; touch "$last"; fi',
        }
        for name, body in stubs.items():
            executable = tools / name
            executable.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            executable.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{tools}:/usr/bin:/bin:/usr/sbin:/sbin",
                                PACKAGE_TEST_CALLS=str(self.calls), SPLITVPN_SKIP_NOTARIZE="1")

    def package(self, content):
        if content is not None:
            self.config.write_bytes(content)
        return subprocess.run(["/bin/bash", str(SCRIPT), str(self.app), str(self.output)],
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def test_empty_object_reaches_packaging(self):
        result = self.package(b" \n{ }\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(), ["create", "verify"])
        self.assertTrue((self.output / "SHA256SUMS").is_file())

    def test_company_fields_rejected_before_packaging_without_logging_values(self):
        result = self.package(b'{"origin":"https://example.test","loginDomain":"fixture","target":"10.0.0.8"}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("非空私有网络配置", result.stderr)
        self.assertNotIn("example.test", result.stdout + result.stderr)
        self.assertNotIn("10.0.0.8", result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())

    def test_other_nonempty_settings_are_rejected(self):
        result = self.package(b'{"unknownFutureField":true}')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_missing_configuration_is_rejected(self):
        result = self.package(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("缺失或格式无效", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_malformed_and_nonobject_configuration_are_rejected(self):
        for content in [b"{", b"[]", b"null", b"false", b'""', b"\xff"]:
            with self.subTest(content=content):
                result = self.package(content)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
