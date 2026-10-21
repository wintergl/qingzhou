"""Exercise download/extraction and prepared-input failure boundaries offline."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import third_party_common as common


class DependencyIntegrityTests(unittest.TestCase):
    def test_changed_cached_download_is_rejected_and_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'source.tar.gz'
            path.write_bytes(b'changed')
            expected = hashlib.sha256(b'expected').hexdigest()
            with patch.object(common, 'run') as network:
                with self.assertRaisesRegex(RuntimeError, 'differs'):
                    common.download('https://example.test/source', expected, path)
                network.assert_not_called()
            self.assertEqual(path.read_bytes(), b'changed')

    def test_source_archives_cannot_escape_or_create_links(self):
        for name, link in [('../../outside', False), ('source/link', True)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / 'source.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    member = tarfile.TarInfo(name)
                    if link:
                        member.type = tarfile.SYMTYPE
                        member.linkname = '../../outside'
                        tar.addfile(member)
                    else:
                        member.size = 1
                        tar.addfile(member, io.BytesIO(b'x'))
                with self.assertRaises(ValueError):
                    common.extract_source(archive, root / 'output')
                self.assertFalse((root / 'output').exists())

    def test_prepared_input_checks_reject_changed_and_missing_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock = root / 'lock.json'
            lock.write_text('{}')
            artifact = root / 'core'
            artifact.write_bytes(b'fixture-core')
            with patch.object(common, 'ROOT', root), patch.object(common, 'LOCAL', root / '.local'), patch.object(common, 'LOCK_PATH', lock):
                common.build_record('fixture', [artifact])
                common.verify_record('fixture')
                artifact.write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError, 'changed'):
                    common.verify_record('fixture')
                artifact.unlink()
                with self.assertRaisesRegex(RuntimeError, 'Missing'):
                    common.verify_record('fixture')

    def test_local_download_cache_link_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'original'
            original.write_bytes(b'kept')
            link = root / 'download'
            link.symlink_to(original)
            with self.assertRaisesRegex(RuntimeError, 'symbolic'):
                common.download('https://example.test/source', '0' * 64, link)
            self.assertEqual(original.read_bytes(), b'kept')


if __name__ == '__main__':
    unittest.main(verbosity=2)
