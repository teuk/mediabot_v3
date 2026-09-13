#!/usr/bin/env python3
"""Execute the actual Debian CI block with a local CPAN process fixture."""
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def dependency_block():
    text = (ROOT / '.github/workflows/debian13.yml').read_text()
    heading = '      - name: Build and verify runtime Perl dependencies on Debian 13\n'
    step = text.split(heading, 1)[1].split('\n      - name:', 1)[0]
    block = step.split('        run: |\n', 1)[1]
    return '\n'.join(line[10:] if line.startswith('          ') else line for line in block.splitlines())+'\n'


class Retry(unittest.TestCase):
    def execute(self, failures=0, log=True, verify_rc=0):
        tmp = tempfile.TemporaryDirectory(prefix='mb734-cpan-contract-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        workspace = root/'workspace with spaces'
        candidate = root/'candidate'
        runner = root/'runner temp'
        fake = root/'bin'
        for path in (workspace/'local', candidate/'install', runner, fake):
            path.mkdir(parents=True)
        (workspace/'local/already-installed').write_text('keep me')
        (candidate/'cpanfile').write_text("requires 'JSON::MaybeXS';\n")
        calls = root/'calls.jsonl'
        cpanm = fake/'cpanm'
        cpanm.write_text('#!'+sys.executable+'''\nimport json,os,sys
from pathlib import Path
p=Path(os.environ['TEST_CALLS'])
rows=p.read_text().splitlines() if p.exists() else []
home=Path(os.environ['PERL_CPANM_HOME'])
assert home.is_dir() and not list(home.iterdir()), 'fresh attempt state required'
assert os.environ['PERL_CPANM_OPT']=='--from https://cpan.metacpan.org'
assert sys.argv[1:]==['--notest','--local-lib',os.environ['GITHUB_WORKSPACE']+'/local','--installdeps','.']
assert Path('cpanfile').is_file(), 'dependencies must come from the exported candidate'
with p.open('a') as f: f.write(json.dumps({'home':str(home),'args':sys.argv[1:]})+'\\n')
assert (Path(os.environ['GITHUB_WORKSPACE'])/'local/already-installed').read_text()=='keep me'
(home/'partial.tar.gz').write_bytes(b'partial archive')
if len(rows)<int(os.environ['TEST_FAILURES']):
 if os.environ['TEST_LOG']=='1': (home/'build.log').write_text('gzip: stdin: unexpected end of file\\n')
 sys.exit(17)
(Path(os.environ['GITHUB_WORKSPACE'])/'local/new-module').write_text('installed')
''')
        cpanm.chmod(0o755)
        (fake/'perl').write_text('#!/bin/sh\nexit 0\n')  # Hailo already loadable.
        (fake/'perl').chmod(0o755)
        (fake/'sleep').write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$TEST_DELAYS"\n')
        (fake/'sleep').chmod(0o755)
        verifier = candidate/'install/cpan_install.sh'
        verifier.write_text('#!/bin/sh\nprintf "verified\\n" >> "$TEST_VERIFY"\nexit '+str(verify_rc)+'\n')
        env = dict(os.environ, PATH=str(fake)+os.pathsep+os.environ['PATH'],
                   GITHUB_WORKSPACE=str(workspace), MEDIABOT_CANDIDATE_ROOT=str(candidate),
                   RUNNER_TEMP=str(runner), PERL_CPANM_OPT='--from https://cpan.metacpan.org',
                   TEST_CALLS=str(calls), TEST_FAILURES=str(failures), TEST_LOG=str(int(log)),
                   TEST_DELAYS=str(root/'delays'), TEST_VERIFY=str(root/'verified'))
        result = subprocess.run(['bash','-e','-o','pipefail','-c',dependency_block()], cwd=candidate,
                                env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=10)
        self.assertEqual((workspace/'local/already-installed').read_text(),'keep me')
        records = [json.loads(line) for line in calls.read_text().splitlines()]
        self.assertEqual(len(records),len({r['home'] for r in records}))
        self.assertTrue(all(Path(r['home'],'partial.tar.gz').is_file() for r in records))
        delays = (root/'delays').read_text().splitlines() if (root/'delays').exists() else []
        return result, records, delays, (root/'verified').exists()

    def test_success_has_no_retry_or_delay(self):
        result, rows, delays, verified = self.execute()
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertEqual(len(rows),1); self.assertEqual(delays,[]); self.assertTrue(verified)

    def test_truncated_download_retries_with_new_cache_and_keeps_modules(self):
        result, rows, delays, verified = self.execute(failures=1)
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertEqual(len(rows),2); self.assertEqual(delays,['5']); self.assertTrue(verified)
        self.assertIn('gzip: stdin: unexpected end of file',result.stdout)

    def test_third_attempt_can_recover(self):
        result, rows, delays, verified = self.execute(failures=2)
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertEqual(len(rows),3); self.assertEqual(delays,['5','10']); self.assertTrue(verified)

    def test_permanent_failure_preserves_exit_code_and_stops_before_verifier(self):
        result, rows, delays, verified = self.execute(failures=99)
        self.assertEqual(result.returncode,17,result.stdout)
        self.assertEqual(len(rows),3); self.assertEqual(delays,['5','10']); self.assertFalse(verified)
        self.assertIn('::error::',result.stdout)

    def test_missing_build_log_does_not_mask_original_failure(self):
        result, rows, _, verified = self.execute(failures=99,log=False)
        self.assertEqual(result.returncode,17,result.stdout)
        self.assertEqual(len(rows),3); self.assertFalse(verified)

    def test_module_verifier_failure_is_never_retried_or_ignored(self):
        result, rows, _, verified = self.execute(verify_rc=23)
        self.assertEqual(result.returncode,23,result.stdout)
        self.assertEqual(len(rows),1); self.assertTrue(verified)

    def test_https_mirror_is_shared_by_both_ci_workflows(self):
        for name in ('ci.yml','debian13.yml'):
            text=(ROOT/'.github/workflows'/name).read_text()
            self.assertRegex(text,r"(?m)^  PERL_CPANM_OPT: '--from https://cpan\.metacpan\.org'$",name)
            self.assertNotIn('http://www.cpan.org',text)
        text=(ROOT/'.github/workflows/ci.yml').read_text()
        self.assertIn('install-modules-with: cpanm',text)
        self.assertIn('install-modules-args: --notest',text)
        self.assertIn("https://cpan.metacpan.org/authors/id/A/AV/AVAR/Hailo-0.75.tar.gz",dependency_block())
        self.assertIn("requires 'JSON::MaybeXS';",(ROOT/'cpanfile').read_text())


if __name__=='__main__':
    output=io.StringIO()
    result=unittest.TextTestRunner(stream=output).run(unittest.defaultTestLoader.loadTestsFromTestCase(Retry))
    if not result.wasSuccessful():
        print(output.getvalue()); raise SystemExit(1)
    print(f'CPAN retry contract: {result.testsRun}/{result.testsRun} OK (actual CI shell; local process fixtures).')
