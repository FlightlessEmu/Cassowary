"""Real Git merges in temporary repos; no network or emulator build required."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('core_upstream', Path(__file__).parents[1] / 'core-upstream.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdatePreservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.original_root = module.ROOT
        self.addCleanup(setattr, module, 'ROOT', self.original_root)
        self.root = Path(self.temp.name) / 'Cassowary with spaces'
        self.remote = Path(self.temp.name) / 'upstream'
        self.root.mkdir()
        self.remote.mkdir()
        module.ROOT = self.root
        for repo in (self.root, self.remote):
            module.subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            module.git(repo, 'config', 'core.autocrlf', 'false')
        self.write(self.remote, 'engine/pixels.txt', 'first\nsecond\nthird\n')
        self.write(self.remote, 'engine/removed.txt', 'remove me\n')
        self.write(self.remote, 'engine/image.bin', b'\0old\xff')
        self.base = module.commit(self.remote, 'Base')
        self.write(self.root, 'cores/Test/engine/pixels.txt', 'local Metal patch\nsecond\nthird\n')
        self.write(self.root, 'cores/Test/engine/image.bin', b'\0old\xff')
        self.write(self.root, 'cores/Test/engine/local.txt', 'local source\n')
        self.write(self.root, 'cores/Test/Wrapper.mm', 'integration outside source mapping\n')
        module.commit(self.root, 'Local changes, including upstream file deletion')
        self.entry = {'url': str(self.remote), 'revision': self.base,
                      'mappings': [{'upstream': 'engine', 'local': 'engine'}]}

    @staticmethod
    def write(root, name, value):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value if isinstance(value, bytes) else value.encode())
        return path

    def prepare(self, revision):
        with contextlib.redirect_stdout(io.StringIO()):
            result = module.prepare('Test', self.entry, revision)
        review = self.root / 'build/upstream/reviews' / f'Test-{revision[:12]}'
        return result, review

    def test_merge_preserves_local_patch_deletion_binary_and_new_upstream_file(self):
        self.write(self.remote, 'engine/pixels.txt', 'first\nsecond\nupstream fix\n')
        self.write(self.remote, 'engine/image.bin', b'\0new\xff')
        executable = self.write(self.remote, 'engine/new.sh', '#!/bin/sh\necho new\n')
        executable.chmod(0o755)
        new = module.commit(self.remote, 'New upstream')
        before = module.git(self.root, 'rev-parse', 'HEAD').stdout
        result, review = self.prepare(new)
        candidate = review / 'candidate'
        self.assertEqual(result, 0)
        self.assertEqual((candidate / 'engine/pixels.txt').read_text(), 'local Metal patch\nsecond\nupstream fix\n')
        self.assertFalse((candidate / 'engine/removed.txt').exists())
        self.assertTrue((candidate / 'engine/local.txt').exists())
        self.assertEqual((candidate / 'engine/image.bin').read_bytes(), b'\0new\xff')
        self.assertTrue((candidate / 'engine/new.sh').stat().st_mode & 0o111)
        self.assertFalse((candidate / 'Wrapper.mm').exists())
        self.assertIn(b'local Metal patch', (review / 'local.patch').read_bytes())
        self.assertEqual(module.git(self.root, 'rev-parse', 'HEAD').stdout, before)
        self.assertEqual((self.root / 'cores/Test/engine/pixels.txt').read_text().splitlines()[2], 'third')
        # The guide's exported update is directly applicable to the real core.
        module.commit(candidate, 'Reviewed merge')
        report = json.loads((review / 'review.json').read_text())
        patch = review / 'update.patch'
        patch.write_bytes(module.git(candidate, 'diff', '--binary', report['local_commit'], 'HEAD').stdout)
        module.git(self.root, 'apply', '--check', '--directory=cores/Test', str(patch))

    def test_conflicts_are_exposed_and_sources_unchanged(self):
        self.write(self.remote, 'engine/pixels.txt', 'upstream same-line change\nsecond\nthird\n')
        new = module.commit(self.remote, 'Conflict')
        result, review = self.prepare(new)
        self.assertEqual(result, 1)
        report = json.loads((review / 'review.json').read_text())
        self.assertEqual(report['conflicts'], ['engine/pixels.txt'])
        self.assertIn('<<<<<<<', (review / 'candidate/engine/pixels.txt').read_text())
        self.assertTrue((self.root / 'cores/Test/engine/pixels.txt').read_text().startswith('local Metal patch'))

    def test_unknown_baseline_and_dirty_sources_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'baseline not recovered'):
            module.prepare('Test', {**self.entry, 'revision': None}, self.base)
        self.write(self.root, 'cores/Test/engine/pixels.txt', 'unsaved edit\n')
        with self.assertRaisesRegex(ValueError, 'commit or stash'):
            self.prepare(self.base)

    def test_existing_review_is_not_overwritten(self):
        self.prepare(self.base)
        with self.assertRaisesRegex(ValueError, 'review already exists'):
            self.prepare(self.base)

    def test_dirty_dependency_cache_is_not_reset(self):
        cached = module.checkout(str(self.remote), self.base, self.root / 'build/cache')
        self.write(cached, 'engine/pixels.txt', 'keep this edit\n')
        with self.assertRaisesRegex(ValueError, 'local changes'):
            module.checkout(str(self.remote), self.base, self.root / 'build/cache')
        self.assertEqual((cached / 'engine/pixels.txt').read_text(), 'keep this edit\n')


if __name__ == '__main__':
    unittest.main()
