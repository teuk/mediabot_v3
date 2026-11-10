#!/usr/bin/env python3
"""Check, or explicitly apply, a patch against an exact clean Git checkout."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import sys


def git(repo, *args, data=None):
    result = subprocess.run(['git', '-C', str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ValueError(result.stderr.decode(errors='replace').strip() or 'Git failed')
    return result.stdout


def guard(repo, base):
    if git(repo, 'rev-parse', 'HEAD').decode().strip() != base:
        raise ValueError('HEAD differs from the required base; obtain a refreshed patch')
    for name in ('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD',
                 'REVERT_HEAD', 'BISECT_LOG', 'index.lock'):
        marker = Path(git(repo, 'rev-parse', '--git-path', name).decode().strip())
        if not marker.is_absolute():
            marker = repo / marker
        if marker.exists():
            raise ValueError('Git operation in progress: ' + name)
    if git(repo, 'status', '--porcelain=v1', '--untracked-files=all'):
        raise ValueError('Checkout is not clean; preserve or commit local work first')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('patch', type=Path)
    parser.add_argument('--repo', type=Path, default=Path('.'))
    parser.add_argument('--base', required=True, help='full reviewed base commit SHA')
    parser.add_argument('--sha256', required=True, help='published patch SHA-256')
    parser.add_argument('--apply', action='store_true', help='apply after checks; default is check only')
    args = parser.parse_args()
    if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', args.base):
        raise ValueError('--base must be a full lowercase commit SHA')
    if not re.fullmatch(r'[0-9a-f]{64}', args.sha256):
        raise ValueError('--sha256 must be a lowercase SHA-256 digest')
    repo = Path(git(args.repo.resolve(), 'rev-parse', '--show-toplevel').decode().strip())
    # Read once: the checked bytes are also the applied bytes.
    data = args.patch.read_bytes()
    if hashlib.sha256(data).hexdigest() != args.sha256:
        raise ValueError('Patch SHA-256 mismatch')
    guard(repo, args.base)
    git(repo, 'apply', '--check', '--index', '--whitespace=error', '-', data=data)
    print(git(repo, 'apply', '--stat', '-', data=data).decode(), end='')
    if args.apply:
        guard(repo, args.base)
        # No --reject/--3way: failure must not partially apply a patch or merge it.
        # Leave the real index untouched for the existing commit.sh workflow.
        git(repo, 'apply', '--whitespace=error', '-', data=data)
        print('[OK] Patch applied; not staged, tested, committed or pushed')
    else:
        print('[OK] Patch accepted; no working-tree or index changes')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as exc:
        print('[KO] ' + str(exc), file=sys.stderr)
        sys.exit(1)
