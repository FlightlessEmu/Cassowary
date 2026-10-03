#!/usr/bin/env python3
"""Check patch replacement against a local Git source, without downloads."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(*args, cwd):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT).decode()


def main():
    script = Path(__file__).resolve().parents[2] / 'prepare-mame-core.sh'
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        remote = root / 'remote'
        remote.mkdir()
        run('git', 'init', cwd=remote)
        run('git', 'config', 'user.name', 'Test', cwd=remote)
        run('git', 'config', 'user.email', 'test@example.invalid', cwd=remote)
        source = remote / 'source.txt'
        source.write_text('original\n')
        run('git', 'add', '.', cwd=remote)
        run('git', 'commit', '-m', 'baseline', cwd=remote)
        revision = run('git', 'rev-parse', 'HEAD', cwd=remote).strip()
        (root / 'Scripts').mkdir()
        shutil.copyfile(script, root / 'Scripts/prepare-mame-core.sh')
        patches = root / 'cores/MAME/patches'
        patches.mkdir(parents=True)
        manifest = root / 'cores/upstream.json'

        def set_revision(value):
            manifest.write_text(json.dumps({
                'cores': {'MAME': {'revision': value, 'url': str(remote)}}
            }))

        set_revision(revision)
        patch = patches / 'mame-headless-clang21-apple.patch'

        def prepare():
            return subprocess.run(['bash', 'Scripts/prepare-mame-core.sh'],
                                  cwd=root, capture_output=True, text=True)

        def set_patch(text):
            source.write_text(text)
            patch.write_text(run('git', 'diff', cwd=remote))
            run('git', 'restore', 'source.txt', cwd=remote)

        set_patch('first patch\n')
        result = prepare()
        assert result.returncode == 0, result.stderr
        cached = root / 'cores/MAME/deps/mame/source.txt'
        assert cached.read_text() == 'first patch\n'
        assert prepare().returncode == 0
        set_patch('updated patch\n')
        result = prepare()
        assert result.returncode == 0, result.stderr
        assert cached.read_text() == 'updated patch\n'
        (remote / 'new.txt').write_text('new upstream file\n')
        run('git', 'add', '.', cwd=remote)
        run('git', 'commit', '-m', 'next revision', cwd=remote)
        set_revision(run('git', 'rev-parse', 'HEAD', cwd=remote).strip())
        result = prepare()
        assert result.returncode == 0, result.stderr
        assert cached.read_text() == 'updated patch\n'
        assert (cached.parent / 'new.txt').exists()
        cached.write_text('manual edit\n')
        set_patch('third patch\n')
        assert prepare().returncode != 0
        assert cached.read_text() == 'manual edit\n'
    print('MAME preparation: first apply, repeat, patch/pin updates, and edit protection passed')


if __name__ == '__main__':
    main()
