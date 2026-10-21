#!/usr/bin/env python3
"""Run isolated reader regressions: python3 apps/macos-native/Tests/reader_memory.py.

Compile the real services with a CLI probe and pipe-only fake children in a
temporary directory. No app, installed core, credentials, or network is used.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[1]
SOURCES = PACKAGE / "Sources" / "SplitVPNNative"
FIXTURE = r'''#!/usr/bin/env python3
import json
import sys
import time

sequence = 0
for line in sys.stdin:
    command = json.loads(line)
    channel = command.get("channel", command.get("type"))
    if channel == "fixture:finish":
        break
    if channel == "fixture:oversize":
        try:
            sys.stdout.buffer.write(b"x" * (9 * 1024 * 1024))
            sys.stdout.buffer.flush()
            sys.stdin.read()  # Wait for the reader to terminate this child.
        except BrokenPipeError:
            pass
        break
    assert channel == "fixture:echo", "Unexpected fixture command"
    sequence += 1
    padding = "x" * 4096
    if "id" in command:
        response = {"id": command["id"], "ok": True,
                    "data": {"padding": padding, "sequence": sequence}}
        prefix = ""
        if sequence == 1:
            prefix = (json.dumps({"event": "fixture:event", "data": padding}) + "\n") * 2
    else:
        response = {"type": "fixture", "id": str(sequence), "message": padding}
        prefix = "invalid-json\n" if sequence == 1 else ""
    wire = (prefix + json.dumps(response, separators=(",", ":")) + "\n").encode()
    if sequence == 1:
        sys.stdout.buffer.write(wire[:37])
        sys.stdout.buffer.flush()
        time.sleep(0.02)  # Force a partial line to survive one pool drain.
        wire = wire[37:]
    sys.stdout.buffer.write(wire)
    sys.stdout.buffer.flush()
'''


@unittest.skipUnless(sys.platform == "darwin", "macOS Foundation reader regression")
class ReaderMemoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="qingzhou-reader-test-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        cls.binary = cls.root / "ReaderMemoryProbe"
        for name in ("splitvpn-core", "company-account-helper"):
            child = cls.root / name
            child.write_text(FIXTURE)
            child.chmod(0o755)
        # Override only for a negative control using saved, pre-fix sources.
        services = Path(os.environ.get("QZ_READER_SOURCE_DIR", SOURCES / "Services"))
        paths = [services / "CoreService.swift", services / "HelperService.swift",
                 SOURCES / "Models" / "VPNModels.swift",
                 SOURCES / "Models" / "AccountModels.swift",
                 SOURCES / "Models" / "NetworkRecoveryRecord.swift",
                 PACKAGE / "Tests" / "ReaderMemoryProbe.swift"]
        build = subprocess.run(
            ["swiftc", "-O", "-module-cache-path", str(cls.root / "module-cache"),
             *map(str, paths), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=90)
        if build.returncode:
            raise RuntimeError(build.stdout + build.stderr)
        cls.environment = dict(os.environ, SPLITVPN_ISOLATED="1",
                               SPLITVPN_DATA_DIR=str(cls.root / "data"),
                               SPLITVPN_RESOURCES=str(cls.root),
                               QZ_READER_FIXTURE_DIR=str(cls.root))

    def run_probe(self, mode):
        result = subprocess.run([str(self.binary), mode], env=self.environment,
                                capture_output=True, text=True,
                                timeout=90 if mode.endswith("oversize") else 30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return {sample["stage"]: sample["mallocInUse"]
                for line in result.stdout.splitlines() if (sample := json.loads(line))}

    def check_memory(self, service):
        samples = self.run_probe(service + "-memory")
        growth = samples["active"] - samples["warm"]
        print(f"{service}: warm={samples['warm']} active={samples['active']} "
              f"growth={growth} bytes", flush=True)
        # 4,000 additional reads retain about 64 MiB without the per-read pool.
        # Leave headroom for Swift tasks and allocator/toolchain differences.
        self.assertLess(growth, 8 * 1024 * 1024, f"{service} retained read temporaries")

    def test_core_memory_fragmented_events_and_eof(self):
        self.check_memory("core")

    def test_helper_memory_fragmented_events_and_eof(self):
        self.check_memory("helper")

    def test_core_oversized_unterminated_message(self):
        self.run_probe("core-oversize")

    def test_helper_oversized_unterminated_message(self):
        self.run_probe("helper-oversize")


if __name__ == "__main__":
    unittest.main(verbosity=2)
