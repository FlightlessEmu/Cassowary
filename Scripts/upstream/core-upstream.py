#!/usr/bin/env python3
"""Inventory cores and prepare upstream merges without changing vendored sources."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / 'cores/upstream.json'
IDENTITY = {'GIT_AUTHOR_NAME': 'Cassowary maintenance', 'GIT_AUTHOR_EMAIL': 'maintenance@localhost',
            'GIT_COMMITTER_NAME': 'Cassowary maintenance', 'GIT_COMMITTER_EMAIL': 'maintenance@localhost'}


def git(directory, *args, check=True):
    return subprocess.run(['git', '-C', str(directory), *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env={**os.environ, **IDENTITY})


def safe_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or '.git' in path.parts or not value:
        raise ValueError(f'unsafe path: {value}')
    return path


def load_manifest():
    data = json.loads(MANIFEST.read_text())
    if data.get('schema') != 1:
        raise ValueError('unsupported upstream inventory schema')
    actual = {p.name for p in (ROOT / 'cores').iterdir() if p.is_dir() and not p.name.startswith('.')}
    if set(data['cores']) != actual:
        raise ValueError(f'core inventory mismatch: {sorted(set(data["cores"]) ^ actual)}')
    for name, entry in {**data['cores'], **data['dependencies']}.items():
        revision = entry.get('revision')
        if revision is not None and not re.fullmatch('[0-9a-f]{40}', revision):
            raise ValueError(f'{name}: pin must be a full commit ID')
        for mapping in entry.get('mappings', []):
            safe_path(mapping['upstream'])
            safe_path(mapping['local'])
            for excluded in mapping.get('exclude', []):
                safe_path(excluded)
        for patch in entry.get('patches', []):
            safe_path(patch)
            if not (ROOT / patch).is_file():
                raise ValueError(f'missing patch: {patch}')
        if name in data['cores'] and entry['shipped']:
            if not re.fullmatch(r'[A-Za-z0-9_-]+', entry.get('product', '')):
                raise ValueError(f'{name}: invalid product name')
    return data


def checkout(url, revision, cache, submodules=False):
    """Immutable cache: a changed pin uses a new checkout, never resets user work."""
    key = hashlib.sha256((url + revision + ('recursive' if submodules else '')).encode()).hexdigest()[:20]
    destination = cache / key
    if not destination.exists():
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='fetch-', dir=cache) as temp:
            repo = Path(temp) / 'repo'
            subprocess.run(['git', 'init', '-q', str(repo)], check=True)
            git(repo, 'remote', 'add', 'origin', url)
            git(repo, 'fetch', '--depth=1', 'origin', revision)
            git(repo, 'checkout', '--detach', 'FETCH_HEAD')
            if git(repo, 'rev-parse', 'HEAD').stdout.decode().strip() != revision:
                raise ValueError('fetched revision did not match pin')
            if submodules:
                git(repo, '-c', 'protocol.file.allow=never', 'submodule', 'update', '--init', '--recursive')
            repo.rename(destination)
    if git(destination, 'rev-parse', 'HEAD').stdout.decode().strip() != revision:
        raise ValueError(f'cache has a different revision: {destination}')
    if git(destination, 'status', '--porcelain', '--untracked-files=normal', '--ignore-submodules=none').stdout:
        raise ValueError(f'cache contains local changes: {destination}; move it aside to preserve them')
    return destination


def tracked(directory, submodules=False):
    args = ['ls-files', '-z']
    if submodules:
        args.append('--recurse-submodules')
    return [Path(os.fsdecode(p)) for p in git(directory, *args).stdout.split(b'\0') if p]


def copy_file(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(os.readlink(source))
    elif source.is_file():
        shutil.copy2(source, destination)
    else:
        raise ValueError(f'missing source or unpopulated dependency: {source}')


def snapshot(source, destination, mappings, local=False):
    files = tracked(ROOT if local else source, submodules=not local)
    for mapping in mappings:
        origin = Path(mapping['local'] if local else mapping['upstream'])
        # Local paths in the manifest are relative to cores/<name>.
        if local:
            origin = source.relative_to(ROOT) / origin
        target = Path(mapping['local'])
        excluded = [Path(p) for p in mapping.get('exclude', [])]
        selected = [p for p in files if (p == origin or origin in p.parents)
                    and not any(p.relative_to(origin) == e or e in p.relative_to(origin).parents for e in excluded)]
        if not selected:
            raise ValueError(f'no tracked files at {source if not local else ROOT}/{origin}')
        for p in selected:
            relative = p.relative_to(origin)
            copy_file((ROOT if local else source) / p, destination / target / relative)


def commit(directory, message):
    git(directory, 'add', '--all', '--force', '.')
    git(directory, 'commit', '--allow-empty', '-qm', message)
    return git(directory, 'rev-parse', 'HEAD').stdout.decode().strip()


def replace_tree(directory, snapshot_dir):
    for child in directory.iterdir():
        if child.name == '.git':
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()
    shutil.copytree(snapshot_dir, directory, dirs_exist_ok=True, symlinks=True)


def prepare(name, entry, revision):
    if not entry.get('revision'):
        raise ValueError(f'{name}: baseline not recovered yet; see docs/core-audit/upstream-maintenance.md')
    if not entry.get('mappings'):
        raise ValueError(f'{name}: no vendored source mapping; downloaded sources such as MAME use their own preparation script')
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('use a full upstream commit ID, not a moving branch or tag')
    local = ROOT / 'cores' / name
    paths = [str(local / mapping['local']) for mapping in entry['mappings']]
    if git(ROOT, 'status', '--porcelain', '--', *paths).stdout:
        raise ValueError(f'commit or stash changes to the mapped sources in cores/{name} before preparing an update')
    cache = ROOT / 'build/upstream/cache'
    old = checkout(entry['url'], entry['revision'], cache, entry.get('submodules', False))
    new = checkout(entry['url'], revision, cache, entry.get('submodules', False))
    destination = ROOT / 'build/upstream/reviews' / f'{name}-{revision[:12]}'
    if destination.exists():
        raise ValueError(f'review already exists: {destination}; keep it or move it aside')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='review-', dir=destination.parent) as temporary:
        temp = Path(temporary)
        for label, source, is_local in [('base', old, False), ('local', local, True), ('upstream', new, False)]:
            snapshot(source, temp / label, entry['mappings'], local=is_local)
        candidate = temp / 'candidate'
        candidate.mkdir()
        subprocess.run(['git', 'init', '-q', str(candidate)], check=True)
        git(candidate, 'config', 'core.autocrlf', 'false')
        git(candidate, 'config', 'core.hooksPath', '/dev/null')
        replace_tree(candidate, temp / 'base')
        base = commit(candidate, 'Pinned upstream baseline')
        replace_tree(candidate, temp / 'local')
        current = commit(candidate, 'Cassowary patches')
        (temp / 'local.patch').write_bytes(git(candidate, 'diff', '--binary', base, current).stdout)
        git(candidate, 'checkout', '-qb', 'upstream', base)
        replace_tree(candidate, temp / 'upstream')
        commit(candidate, 'Proposed upstream revision')
        git(candidate, 'checkout', '--detach', current)
        result = git(candidate, '-c', 'merge.renames=true', 'merge', '--no-commit', '--no-ff', 'upstream', check=False)
        conflicts = git(candidate, 'diff', '--name-only', '--diff-filter=U').stdout.decode().splitlines()
        if result.returncode and not conflicts:
            raise ValueError(result.stderr.decode())
        report = {'core': name, 'old_revision': entry['revision'], 'new_revision': revision,
                  'cassowary_commit': git(ROOT, 'rev-parse', 'HEAD').stdout.decode().strip(),
                  'local_commit': current, 'conflicts': conflicts,
                  'mappings': entry['mappings'], 'tested': False}
        (temp / 'review.json').write_text(json.dumps(report, indent=2) + '\n')
        (temp / 'README.txt').write_text(
            'candidate/ is a separate Git repository. Vendored sources have not changed.\n'
            'local.patch records every existing local change inside the mapped paths.\n'
            'Resolve conflicts in candidate/, then: git add -A; git commit\n'
            f'Export the reviewed update: git diff --binary {current} HEAD > ../update.patch\n'
            f'From Cassowary: git apply --check --directory=cores/{name} <review>/update.patch\n'
            f'Then: git apply --directory=cores/{name} <review>/update.patch\n'
            'Update the manifest pin, rebuild the changed core and its libraries, restage the app,\n'
            'and test games on the target platforms before landing. See the maintenance guide.\n')
        # Keep only the reviewable result, not three extra copies of the source.
        for label in ('base', 'local', 'upstream'):
            shutil.rmtree(temp / label)
        Path(temporary).rename(destination)
    print(f'Review: {destination}')
    print(f'{len(conflicts)} conflict(s). Sources and manifest are unchanged.')
    return 1 if conflicts else 0


def fetch_dependency(name, entry):
    patches = [ROOT / p for p in entry.get('patches', [])]
    digest = hashlib.sha256(b''.join(p.read_bytes() for p in patches)).hexdigest()[:12]
    cache = ROOT / 'build/upstream/dependencies'
    destination = cache / f'{name}-{entry["revision"][:12]}-{digest}'
    if not destination.exists():
        source = checkout(entry['url'], entry['revision'], ROOT / 'build/upstream/cache', entry.get('submodules', False))
        cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='dependency-', dir=cache) as temporary:
            prepared = Path(temporary) / 'repo'
            shutil.copytree(source, prepared, symlinks=True)
            for patch in patches:
                git(prepared, 'apply', '--check', str(patch))
                git(prepared, 'apply', str(patch))
            commit(prepared, 'Cassowary dependency patches')
            prepared.rename(destination)
    if git(destination, 'status', '--porcelain', '--untracked-files=normal').stdout:
        raise ValueError(f'dependency contains local changes: {destination}; move it aside to preserve them')
    print(destination)
    return 0


def remote_status(data):
    """Report activity and release metadata, without choosing or importing updates."""
    print(f'Checked: {datetime.now(timezone.utc).isoformat()}')
    failures = 0
    for name, entry in {**data['cores'], **data['dependencies']}.items():
        url = entry.get('engine_url', entry['url']).removesuffix('.git')
        match = re.fullmatch(r'https://github.com/([^/]+/[^/]+)', url)
        if not match:
            print(f'{name}: check {url} manually; pin {entry.get("revision") or "UNKNOWN"}')
            continue
        headers = {'User-Agent': 'Cassowary-core-maintenance', 'Accept': 'application/vnd.github+json'}
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        if token:
            headers['Authorization'] = f'Bearer {token}'
        try:
            request = urllib.request.Request(f'https://api.github.com/repos/{match[1]}/commits?per_page=1', headers=headers)
            with urllib.request.urlopen(request, timeout=30) as response:
                latest = json.load(response)[0]
            date = latest['commit']['committer']['date']
            print(f'{name}: latest commit {latest["sha"]} ({date}); pin {entry.get("revision") or "UNKNOWN"}; {url}')
        except (urllib.error.URLError, KeyError, IndexError) as error:
            print(f'{name}: could not check upstream ({error}); {url}')
            failures += 1
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('check', help='validate the offline inventory')
    commands.add_parser('list', help='show all cores and baseline gaps')
    commands.add_parser('shipped', help='print the app core list as JSON')
    commands.add_parser('products', help='print source:product pairs for the app build')
    commands.add_parser('changed', help='read changed filenames from stdin and print affected staged cores as JSON')
    commands.add_parser('remote-status', help='check upstream activity online; never updates sources')
    update = commands.add_parser('prepare', help='prepare an isolated three-way upstream merge')
    update.add_argument('core')
    update.add_argument('revision')
    dependency = commands.add_parser('fetch-dependency', help='prepare a pinned external source with its patches')
    dependency.add_argument('name')
    args = parser.parse_args()
    data = load_manifest()
    if args.command == 'check':
        print(f'OK: {len(data["cores"])} cores inventoried; {sum(bool(c.get("revision")) for c in data["cores"].values())} upstream baselines pinned.')
    elif args.command == 'list':
        for name, entry in data['cores'].items():
            print(f'{name:16} {"shipped" if entry["shipped"] else "not staged":11} {entry.get("revision") or "BASELINE UNKNOWN"}')
    elif args.command == 'shipped':
        print(json.dumps([name for name, entry in data['cores'].items() if entry['shipped']]))
    elif args.command == 'products':
        print('\n'.join(f'{name}:{entry["product"]}' for name, entry in data['cores'].items() if entry['shipped']))
    elif args.command == 'changed':
        changed = sys.stdin.read().splitlines()
        shared = ('OpenEmu-SDK/', 'OpenEmuKit/', 'OpenEmu-Shaders/', 'OpenEmu-metal.xcworkspace/',
                  'Scripts/cassowary/', 'Scripts/upstream/', 'Scripts/prepare-mame-core.sh', 'cores/upstream.json')
        all_cores = [name for name, entry in data['cores'].items() if entry['shipped']]
        selected = all_cores if any(p.startswith(shared) for p in changed) else [
            name for name in all_cores if any(p.startswith(f'cores/{name}/') for p in changed)]
        print(json.dumps(selected))
    elif args.command == 'prepare':
        return prepare(args.core, data['cores'][args.core], args.revision)
    elif args.command == 'remote-status':
        return remote_status(data)
    else:
        return fetch_dependency(args.name, data['dependencies'][args.name])
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors='replace') if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        print(f'error: {detail}', file=sys.stderr)
        sys.exit(2)
