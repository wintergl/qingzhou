"""Offline tests for copying prebuilt third-party notices into an app."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("stage_notices", SCRIPTS / "stage-notices.py")
assert SPEC and SPEC.loader
stage_notices = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(stage_notices)


class PrebuiltNoticeCopyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def make_notices(self, name="source", platform="ios"):
        directory = self.root / name
        directory.mkdir()
        for component in stage_notices.SELECTION[platform]:
            (directory / f"{component}.LICENSE").write_text("license\n")
        (directory / "Qingzhou-Original-Code.LICENSE").write_text("license\n")
        (directory / "LICENSES.md").write_text("notices\n")
        (directory / "rust").mkdir()
        (directory / "rust" / "crate.LICENSE").write_text("license\n")
        inventory = {
            "platform": platform,
            "components": {name: {} for name in stage_notices.SELECTION[platform]},
            "rust_packages": [{"name": "fixture", "version": "1.0.0"}],
            "go_modules": {"sing_box": []} if platform == "ios" else {},
            "geo_data": {},
        }
        (directory / "dependency-inventory.json").write_text(json.dumps(inventory))
        return directory

    def test_complete_tree_replaces_owned_output_without_stale_files(self):
        source = self.make_notices()
        output = self.make_notices("output")
        (output / "stale.txt").write_text("remove me")

        stage_notices.copy_prebuilt_notices(source, output, "ios")

        self.assertFalse((output / "stale.txt").exists())
        self.assertEqual(
            (output / "dependency-inventory.json").read_text(),
            (source / "dependency-inventory.json").read_text(),
        )
        self.assertTrue((source / "rust" / "crate.LICENSE").is_file())

    def test_incomplete_wrong_platform_and_missing_inventory_are_rejected(self):
        for name, mutate, message in (
            (
                "incomplete",
                lambda value: value.update(status="preparing"),
                "incomplete",
            ),
            (
                "wrong-platform",
                lambda value: value.update(platform="macos-arm64"),
                "different platform",
            ),
        ):
            with self.subTest(name=name):
                source = self.make_notices(name)
                marker = source / "dependency-inventory.json"
                inventory = json.loads(marker.read_text())
                mutate(inventory)
                marker.write_text(json.dumps(inventory))
                with self.assertRaisesRegex(ValueError, message):
                    stage_notices.copy_prebuilt_notices(source, self.root / f"{name}-out", "ios")

        source = self.make_notices("missing")
        (source / "dependency-inventory.json").unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            stage_notices.copy_prebuilt_notices(source, self.root / "missing-out", "ios")

    def test_symbolic_links_are_rejected_without_touching_their_target(self):
        source = self.make_notices()
        external = self.root / "external"
        external.write_text("kept")
        (source / "linked-license").symlink_to(external)

        with self.assertRaisesRegex(ValueError, "symbolic"):
            stage_notices.copy_prebuilt_notices(source, self.root / "output", "ios")

        self.assertEqual(external.read_text(), "kept")

    def test_cli_does_not_follow_an_output_directory_symlink(self):
        source = self.make_notices()
        external = self.root / "external-output"
        external.mkdir()
        sentinel = external / "sentinel"
        sentinel.write_text("kept")
        output = self.root / "output-link"
        output.symlink_to(external, target_is_directory=True)

        with self.assertRaisesRegex(ValueError, "symbolic"):
            stage_notices.main([
                "--platform", "ios",
                "--output", str(output),
                "--copy-from", str(source),
            ])

        self.assertTrue(output.is_symlink())
        self.assertEqual(sentinel.read_text(), "kept")

    def test_unowned_output_and_overlapping_paths_are_rejected(self):
        source = self.make_notices()
        output = self.root / "unowned"
        output.mkdir()
        sentinel = output / "sentinel"
        sentinel.write_text("kept")

        with self.assertRaisesRegex(ValueError, "unowned"):
            stage_notices.copy_prebuilt_notices(source, output, "ios")
        self.assertEqual(sentinel.read_text(), "kept")

        with self.assertRaisesRegex(ValueError, "overlap"):
            stage_notices.copy_prebuilt_notices(source, source / "nested", "ios")

    def test_failed_replacement_restores_output_without_leaving_an_empty_backup(self):
        source = self.make_notices()
        output = self.make_notices("output")
        sentinel = output / "old-sentinel"
        sentinel.write_text("kept")
        original_rename = Path.rename

        def fail_staged_rename(path, target):
            path = Path(path)
            target = Path(target)
            if target.resolve() == output.resolve() and path.parent.name.startswith(".output.copy-"):
                raise OSError("injected replacement failure")
            return original_rename(path, target)

        with patch.object(Path, "rename", new=fail_staged_rename):
            with self.assertRaisesRegex(OSError, "injected"):
                stage_notices.copy_prebuilt_notices(source, output, "ios")

        self.assertEqual(sentinel.read_text(), "kept")
        self.assertEqual(list(self.root.glob(".output.previous-*")), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
