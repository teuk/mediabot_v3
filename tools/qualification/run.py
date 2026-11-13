#!/usr/bin/env python3
"""Qualify one committed source tree without copying deployment files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time


def git(repo, *args):
    return subprocess.check_output(['git', '-C', str(repo), *args], stderr=subprocess.PIPE, timeout=120)


def snapshot(repo, target):
    commit = git(repo, 'rev-parse', '--verify', 'HEAD^{commit}').decode().strip()
    # A private clone retains .github and Git metadata used by native cases;
    # git archive would omit export-ignore paths and invalidate those tests.
    subprocess.run(['git', 'clone', '--quiet', '--no-local', '--no-checkout',
                    str(repo), str(target)], check=True, timeout=120)
    git(target, 'checkout', '--quiet', '--detach', commit)
    for entry in git(target, 'ls-files', '-z').decode().split('\0'):
        if entry and (target / entry).is_symlink():
            raise ValueError('Unsupported source symlink: ' + entry)
    return commit


def run_stage(name, command, cwd, env, timeout):
    start = time.monotonic()
    result = {'name': name, 'command': command, 'status': 'failed'}
    print('[RUN] ' + name, flush=True)
    try:
        child = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
    except OSError as exc:
        result.update(status='unavailable', error=type(exc).__name__)
    else:
        try:
            code = child.wait(timeout=timeout)
            result.update(returncode=code, status='passed' if code == 0 else 'failed')
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
            # Retire the complete test process group, including child workers.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            result['status'] = 'timeout' if isinstance(exc, subprocess.TimeoutExpired) else 'interrupted'
    result['elapsed_s'] = round(time.monotonic() - start, 3)
    return result


def qualify(repo, output, lane, timeout, perl_lib=None):
    # mkdir is exclusive: never replace an earlier report or follow its symlink.
    output.mkdir(mode=0o700)
    report = {'schema': 1, 'lane': lane, 'status': 'unavailable', 'stages': [],
              'python': platform.python_version(), 'platform': platform.system(),
              'tool_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'scope': 'committed source snapshot; not a live bot or network-isolation proof'}
    code = 3
    try:
        with tempfile.TemporaryDirectory(prefix='mediabot-qualification-') as tmp:
            source = Path(tmp) / 'source'
            source.mkdir()
            report['commit'] = snapshot(repo, source)
            # Remove Perl execution injection and ambient module paths. An explicit
            # dependency tree can be supplied without importing runtime config.
            env = os.environ.copy()
            for key in ('PERL5OPT', 'PERL5LIB', 'PERLLIB'):
                env.pop(key, None)
            if perl_lib:
                env['PERL5LIB'] = str(perl_lib.resolve())
            env['HOME'] = tmp
            env['TMPDIR'] = tmp
            commands = [('runtime_dependencies', ['bash', 'install/cpan_install.sh', '--verify-only']),
                        ('test_dependencies', ['perl', '-MDBD::SQLite', '-e',
                         'print "Perl $^V; SQLite $DBD::SQLite::VERSION\\n";'])]
            if lane != 'preflight':
                commands.append(('tests', ['perl', 't/test_commands.pl',
                    *(['--fast'] if lane == 'fast' else []), '--progress']))
            report['status'] = 'passed'
            code = 0
            for name, command in commands:
                result = run_stage(name, command, source, env, timeout)
                report['stages'].append(result)
                if result['status'] != 'passed':
                    report['status'] = ('unavailable' if name.endswith('dependencies') else result['status'])
                    code = 130 if result['status'] == 'interrupted' else 3 if report['status'] == 'unavailable' else 2
                    break
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        report.update(status='unavailable', error=type(exc).__name__)
        code = 3
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('[RESULT] ' + report['status'] + ' — ' + str(output / 'report.json'), flush=True)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, required=True, help='new report directory; must not exist')
    parser.add_argument('--lane', choices=['preflight', 'fast', 'full'], default='preflight')
    parser.add_argument('--timeout', type=float, default=1200, help='maximum seconds per stage')
    parser.add_argument('--perl-lib', type=Path, help='explicit installed local/lib/perl5 dependency tree')
    args = parser.parse_args()
    if not 0 < args.timeout <= 86400:
        parser.error('--timeout must be positive and at most 86400')
    if args.perl_lib and not args.perl_lib.is_dir():
        parser.error('--perl-lib must be an existing directory')
    try:
        return qualify(args.repo.resolve(), args.output.resolve(), args.lane, args.timeout, args.perl_lib)
    except OSError as exc:
        parser.exit(3, 'Cannot create report directory: ' + str(exc) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
