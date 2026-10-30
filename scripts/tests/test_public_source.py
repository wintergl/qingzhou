"""Check privacy boundaries using an independent, temporary source repository."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PublicSourceTests(unittest.TestCase):
    def scan(self, filename, content):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'scripts').mkdir()
            checker = Path(__file__).resolve().parents[1] / 'check_public_source.py'
            shutil.copyfile(checker, root / 'scripts/check_public_source.py')
            (root / filename).write_text(content)
            result = subprocess.run([sys.executable, root / 'scripts/check_public_source.py'],
                                    capture_output=True, text=True)
            return result.returncode, json.loads(result.stdout), result.stdout

    def test_kotlin_qualified_this_is_not_an_email(self):
        code, report, _ = self.scan('Page.kt', 'setTextColor(this' + '@Page.foreground)\n')
        self.assertEqual(code, 0)
        self.assertEqual(report['findings'], [])

    def test_kotlin_string_containing_an_email_is_still_rejected(self):
        code, report, output = self.scan('Page.kt', 'val email = "this' + '@private.invaliddomain"\n')
        self.assertEqual(code, 1)
        self.assertIn('non-example-email', [item['kind'] for item in report['findings']])
        self.assertNotIn('private.invaliddomain', output)

    def test_home_paths_and_private_keys_are_reported_without_values(self):
        content = '/Users/' + 'private-fixture/secret\n-----BEGIN ' + 'PRIVATE KEY-----\n'
        code, report, output = self.scan('fixture.txt', content)
        self.assertEqual(code, 1)
        self.assertEqual({item['kind'] for item in report['findings']},
                         {'user-home-path', 'private-key'})
        self.assertNotIn('private-fixture', output)

    def test_reserved_example_email_remains_usable(self):
        code, report, _ = self.scan('fixture.txt', 'user@example.test\n')
        self.assertEqual(code, 0)
        self.assertEqual(report['findings'], [])


if __name__ == '__main__':
    unittest.main()
