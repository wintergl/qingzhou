#!/usr/bin/env python3
"""Exercise the shipped installer with private paths and mocked launchctl.

No administrator authorization, launchd job or installed file is touched.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ASSET = Path(__file__).resolve().parents[1] / 'assets/macos-helper-install.sh'


class HelperInstallTests(unittest.TestCase):
    def exercise(self, fail=None, existing=True):
        with tempfile.TemporaryDirectory(prefix='splitvpn-install-') as directory:
            root = Path(directory)
            stage, tools, daemons, backups = [root / name for name in ['stage', 'tools', 'daemons', 'backups']]
            for folder in [stage, tools, daemons]:
                folder.mkdir()
            files = {tools / 'com.split-vpn.helper': 'old helper', tools / 'com.split-vpn.mihomo': 'old engine',
                     daemons / 'com.split-vpn.helper.plist': 'old plist'}
            if existing:
                for path, content in files.items():
                    path.write_text(content)
            (stage / 'helper.sh').write_text('new helper')
            (stage / 'helper.plist').write_text('new plist')
            binary = root / 'new engine'
            binary.write_text('new engine')
            mock = root / 'launchctl'
            mock.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_EVENTS"
if [ "${TEST_FAIL:-}" = "$1" ] && [ ! -f "$TEST_FAILED" ]; then
  touch "$TEST_FAILED"
  exit 1
fi
''')
            mock.chmod(0o755)
            install = root / 'install'
            install.write_text('''#!/bin/sh
shift 4
exec /usr/bin/install "$@"
''')
            install.chmod(0o755)
            digest = lambda text: hashlib.sha256(text.encode()).hexdigest()
            hashes = [digest('new helper'), digest('new plist'), digest('new engine')]
            if fail == 'tampered':
                (stage / 'helper.sh').write_text('swapped helper')
            env = dict(os.environ, TEST_EVENTS=str(root / 'events'), TEST_FAILED=str(root / 'failed'), TEST_FAIL=fail or '')
            if fail == 'staging':
                binary.unlink()
            result = subprocess.run(['/bin/sh', str(ASSET), str(stage), str(binary), str(tools), str(daemons),
                                     str(backups), str(mock), str(install), *hashes], env=env, capture_output=True, text=True)
            events = (root / 'events').read_text().splitlines() if (root / 'events').exists() else []
            saved = list(backups.glob('upgrade.*'))
            self.assertEqual(len(saved), 1 if fail else 0)
            self.assertFalse(list(backups.glob('stage.*')))
            self.assertFalse(list(tools.glob('*.next')) + list(daemons.glob('*.next')))
            self.assertFalse(any('kickstart -k' in line for line in events))
            if fail:
                self.assertNotEqual(result.returncode, 0)
                for path, original in files.items():
                    if existing:
                        self.assertEqual(path.read_text(), original)
                        self.assertEqual((saved[0] / path.name).read_text(), original)
                    else:
                        self.assertFalse(path.exists())
                if fail in ('staging', 'tampered'):
                    self.assertEqual(events, [])
                elif existing:
                    self.assertEqual(sum(line.startswith('bootstrap ') for line in events), 2)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                for path in files:
                    self.assertEqual(path.read_text(), files[path].replace('old', 'new'))
                self.assertEqual(sum(line.startswith('bootstrap ') for line in events), 1)
                self.assertEqual(sum(line.startswith('bootout ') for line in events), 1)

    def test_upgrade_keeps_previous_files_and_only_starts_new_daemon_once(self):
        self.exercise()

    def test_swapped_staging_file_is_rejected_before_any_change(self):
        self.exercise(fail='tampered')

    def test_failed_bootstrap_restores_old_files_and_daemon(self):
        self.exercise(fail='bootstrap')

    def test_failed_preparation_leaves_old_daemon_alone(self):
        self.exercise(fail='staging')

    def test_fresh_install_failure_does_not_leave_partial_system_files(self):
        self.exercise(fail='bootstrap', existing=False)

    def test_fresh_install_succeeds(self):
        self.exercise(existing=False)


if __name__ == '__main__':
    unittest.main()
