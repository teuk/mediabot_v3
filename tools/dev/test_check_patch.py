"""Offline Git integration tests; no project repository or remote is modified."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name('check-patch.py').resolve()


class PatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.name', 'Patch Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'a.txt').write_text('before\n')
        (self.repo / 'b.txt').write_text('old\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'base')
        self.base = self.git('rev-parse', 'HEAD').decode().strip()
        (self.repo / 'a.txt').write_text('after\n')
        (self.repo / 'b.txt').unlink()
        (self.repo / 'new.txt').write_text('new\n')
        self.git('add', '.')
        self.patch = self.root / 'change.patch'
        self.patch.write_bytes(self.git('diff', '--cached', '--binary', '--full-index'))
        self.git('reset', '--hard', 'HEAD')
        self.digest = hashlib.sha256(self.patch.read_bytes()).hexdigest()

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE)

    def call(self, *extra):
        return subprocess.run([sys.executable, str(TOOL), str(self.patch),
                               '--repo', str(self.repo), '--base', self.base,
                               '--sha256', self.digest, *extra], capture_output=True, text=True)

    def test_check_is_read_only(self):
        self.assertEqual(self.call().returncode, 0)
        self.assertEqual(self.git('status', '--porcelain'), b'')
        self.assertEqual((self.repo/'a.txt').read_text(), 'before\n')

    def test_apply_add_modify_delete_without_staging(self):
        self.assertEqual(self.call('--apply').returncode, 0)
        self.assertEqual((self.repo/'a.txt').read_text(), 'after\n')
        self.assertFalse((self.repo/'b.txt').exists())
        self.assertEqual((self.repo/'new.txt').read_text(), 'new\n')
        self.assertEqual(self.git('diff', '--cached', '--name-only'), b'')
        self.assertNotEqual(self.call('--apply').returncode, 0)

    def test_wrong_base(self):
        self.assertNotEqual(self.call('--base', '0'*40, '--apply').returncode, 0)
        self.assertEqual(self.git('status', '--porcelain'), b'')

    def test_tampered_patch(self):
        self.patch.write_bytes(self.patch.read_bytes()+b'\n')
        self.assertNotEqual(self.call('--apply').returncode, 0)
        self.assertEqual(self.git('status', '--porcelain'), b'')

    def test_local_work_preserved(self):
        for stage in (False, True):
            (self.repo/'a.txt').write_text('local\n')
            if stage:
                self.git('add', 'a.txt')
            self.assertNotEqual(self.call('--apply').returncode, 0)
            self.assertEqual((self.repo/'a.txt').read_text(), 'local\n')
            self.git('reset', '--hard', 'HEAD')

    def test_untracked_work_preserved(self):
        (self.repo/'notes.txt').write_text('private\n')
        self.assertNotEqual(self.call('--apply').returncode, 0)
        self.assertEqual((self.repo/'notes.txt').read_text(), 'private\n')

    def test_git_operation(self):
        (self.repo/'.git/MERGE_HEAD').write_text(self.base+'\n')
        self.assertNotEqual(self.call('--apply').returncode, 0)
        self.assertEqual((self.repo/'a.txt').read_text(), 'before\n')

    def test_conflict_is_not_partially_applied(self):
        data = self.patch.read_bytes().replace(b'-old\n', b'-unrelated\n')
        self.patch.write_bytes(data)
        self.digest = hashlib.sha256(data).hexdigest()
        self.assertNotEqual(self.call('--apply').returncode, 0)
        self.assertEqual(self.git('status', '--porcelain'), b'')
        self.assertEqual((self.repo/'a.txt').read_text(), 'before\n')

    def test_ignored_destination_is_not_overwritten(self):
        (self.repo/'.git/info/exclude').write_text('new.txt\n')
        (self.repo/'new.txt').write_text('keep\n')
        self.assertNotEqual(self.call('--apply').returncode, 0)
        self.assertEqual((self.repo/'new.txt').read_text(), 'keep\n')


if __name__ == '__main__':
    unittest.main()
