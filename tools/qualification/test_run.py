import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('qualification', Path(__file__).with_name('run.py'))
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)

class QualificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Qualification test')
        for name, data in {'.gitignore':'secret.conf\n', 'tracked':'committed',
                           'install/cpan_install.sh':'exit 0\n', 'cpanfile':'# fixture\n'}.items():
            p = self.repo / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(data)
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.output = self.root / 'report'

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], stderr=subprocess.PIPE)

    def test_snapshot_only_committed_files(self):
        (self.repo/'secret.conf').write_text('private')
        (self.repo/'untracked').write_text('private')
        (self.repo/'tracked').write_text('dirty')
        dest=self.root/'copy';dest.mkdir()
        commit=q.snapshot(self.repo,dest)
        self.assertEqual(commit,self.git('rev-parse','HEAD').decode().strip())
        self.assertEqual((dest/'tracked').read_text(),'committed')
        self.assertFalse((dest/'secret.conf').exists())
        self.assertFalse((dest/'untracked').exists())
        self.assertTrue((dest/'.git').is_dir())

    def test_link_rejected(self):
        (self.repo/'link').symlink_to('/etc/passwd');self.git('add','link');self.git('commit','-qm','link')
        dest=self.root/'copy';dest.mkdir()
        with self.assertRaises(ValueError):q.snapshot(self.repo,dest)

    def test_missing_dependency_is_not_a_pass(self):
        with patch.object(q,'run_stage',return_value={'status':'failed','returncode':1}) as run:
            self.assertEqual(q.qualify(self.repo,self.output,'full',2),3)
        self.assertEqual(run.call_count,1)
        self.assertEqual(json.loads((self.output/'report.json').read_text())['status'],'unavailable')

    def test_lanes_environment_and_disposal(self):
        for lane,expected in [('preflight',3),('fast',4),('full',4)]:
            output=self.root/lane
            with patch.dict(os.environ,{'PERL5OPT':'bad','PERL5LIB':'secret','PERLLIB':'secret'}):
                with patch.object(q,'run_stage',return_value={'status':'passed','returncode':0}) as run:
                    self.assertEqual(q.qualify(self.repo,output,lane,2),0)
            self.assertEqual(run.call_count,expected)
            args=run.call_args.args
            self.assertFalse(args[2].exists())
            self.assertNotIn('PERL5OPT',args[3]);self.assertNotIn('PERL5LIB',args[3]);self.assertNotIn('PERLLIB',args[3])
            if lane!='preflight':
                self.assertEqual('--fast' in args[1],lane=='fast');self.assertIn('--progress',args[1])

    def test_test_failure_preserved(self):
        with patch.object(q,'run_stage',side_effect=[{'status':'passed'},{'status':'passed'},{'status':'passed'},{'status':'failed','returncode':7}]):
            self.assertEqual(q.qualify(self.repo,self.output,'full',2),2)
        report=json.loads((self.output/'report.json').read_text())
        self.assertEqual(report['status'],'failed');self.assertEqual(report['stages'][-1]['returncode'],7)

    def test_refuse_existing_report(self):
        self.output.mkdir();(self.output/'report.json').write_text('keep')
        with self.assertRaises(FileExistsError):q.qualify(self.repo,self.output,'preflight',2)
        self.assertEqual((self.output/'report.json').read_text(),'keep')

    def test_bad_repository_report(self):
        self.assertEqual(q.qualify(self.root,self.output,'preflight',2),3)
        self.assertEqual(json.loads((self.output/'report.json').read_text())['status'],'unavailable')

    def test_native_stage_outcomes(self):
        for command,status in [(['sh','-c','exit 0'],'passed'),(['sh','-c','exit 7'],'failed'),
                               (['/missing/qualification-tool'],'unavailable'),(['sh','-c','sleep 10'],'timeout')]:
            result=q.run_stage('fixture',command,self.repo,os.environ.copy(),0.1)
            self.assertEqual(result['status'],status)

    def test_provision_is_explicit_contained_and_disposable(self):
        polluted = {key: 'ambient' for key in
                    ('PERL_MM_OPT', 'PERL_MB_OPT', 'PERL_LOCAL_LIB_ROOT',
                     'PERL_CPANM_OPT', 'CPAN_HOME', 'BASH_ENV', 'ENV')}
        with patch.dict(os.environ, polluted):
            with patch.object(q, 'run_stage', return_value={'status': 'passed'}) as run:
                self.assertEqual(q.qualify(self.repo, self.output, 'fast', 2, provision=True), 0)
        calls = [call.args for call in run.call_args_list]
        self.assertEqual(len(calls), 7)
        self.assertEqual(calls[0][1][-2:], ['--installdeps', '.'])
        self.assertEqual(calls[1][1][-1], 'DBD::SQLite')
        self.assertTrue(calls[2][1][-1].endswith('/Hailo-0.75.tar.gz'))
        local = Path(calls[0][1][3])
        self.assertEqual(calls[0][1][:3], ['cpanm', '--notest', '--local-lib-contained'])
        self.assertEqual(calls[0][1][4:6], ['--from', 'https://cpan.metacpan.org'])
        self.assertFalse(local.parent.exists())
        for _, _, _, env, _ in calls:
            self.assertEqual(env['PERL5LIB'], str(local / 'lib/perl5'))
            self.assertFalse(set(polluted) & set(env))
        report = json.loads((self.output/'report.json').read_text())
        self.assertTrue(report['provision'])
        self.assertEqual(set(report['dependency_inputs']), {'cpanfile', 'install/cpan_install.sh'})

    def test_failed_provision_stops_before_tests(self):
        with patch.object(q, 'run_stage', return_value={'status': 'failed', 'returncode':1}) as run:
            self.assertEqual(q.qualify(self.repo,self.output,'full',2,provision=True),3)
        self.assertEqual(run.call_count,1)
        with self.assertRaises(ValueError):
            q.qualify(self.repo,self.root/'another','full',2,self.root,provision=True)
        self.assertFalse((self.root/'another').exists())

    def test_native_inventory_records_missing_and_loaded_modules(self):
        script = Path(__file__).with_name('inventory.pl')
        installer = self.repo/'install/cpan_install.sh'
        installer.write_text('PERL_MODULES=(\n  "File::Basename"\n  "Missing::MB1292"\n)\n')
        dest = self.root/'environment.json'
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('PERL'): env.pop(key)
        result = subprocess.run(['perl',str(script),str(dest)],cwd=self.repo,env=env)
        self.assertEqual(result.returncode,1)
        report = json.loads(dest.read_text())
        modules = {r['module']:r for r in report['required']}
        self.assertEqual(modules['File::Basename']['status'],'loaded')
        self.assertTrue(modules['File::Basename']['version'])
        self.assertEqual(modules['Missing::MB1292']['status'],'unavailable')
        import hashlib
        loaded = {r['file']:r for r in report['loaded_files']}
        entry = loaded['File/Basename.pm']
        self.assertEqual(entry['sha256'],hashlib.sha256(Path(entry['path']).read_bytes()).hexdigest())
        dest.unlink()
        installer.write_text('PERL_MODULES=(\n  dynamic_expression\n)\n')
        result = subprocess.run(['perl',str(script),str(dest)],cwd=self.repo,env=env,
                                capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(dest.exists())

    def test_cli_refuses_report_symlink_without_following_it(self):
        target=self.root/'absent'
        self.output.symlink_to(target)
        result=subprocess.run(['python3',str(Path(q.__file__)), '--repo', str(self.repo),
                               '--output',str(self.output)],capture_output=True)
        self.assertEqual(result.returncode,3)
        self.assertFalse(target.exists())

    def test_native_inventory_moose_marker_and_missing_real_file(self):
        # Match Class::MOP::Package::create's real %INC marker without requiring
        # Moose on the Python tooling host. Only the Perl dependencies are fixtures.
        script = Path(__file__).with_name('inventory.pl')
        lib = self.root/'lib'
        for name in ('Module/Build.pm', 'DBD/SQLite.pm'):
            p=lib/name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('1;\n')
        (lib/'Fixture.pm').write_text(
            "$INC{'Class/MOP/Class/Immutable/Class/MOP/Class.pm'} = '(set by Moose)'; 1;\n")
        (self.repo/'install/cpan_install.sh').write_text('PERL_MODULES=(\n  "Fixture"\n)\n')
        env = os.environ.copy()
        for key in list(env):
            if key.startswith('PERL'): env.pop(key)
        dest = self.root/'inventory.json'
        command=['perl','-I'+str(lib),str(script),str(dest)]
        result=subprocess.run(command,cwd=self.repo,env=env,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr.decode())
        report=json.loads(dest.read_text())
        self.assertEqual(report['generated_modules'],[{
            'file':'Class/MOP/Class/Immutable/Class/MOP/Class.pm',
            'origin':'(set by Moose)'}])
        self.assertTrue(all(r['sha256'] for r in report['loaded_files']))
        self.assertNotIn('(set by Moose)',[r['path'] for r in report['loaded_files']])
        # An actual path that disappeared must still fail, never become generated.
        dest.unlink()
        (lib/'Fixture.pm').write_text("$INC{'Gone.pm'} = '/missing/mb1293/Gone.pm'; 1;\n")
        result=subprocess.run(command,cwd=self.repo,env=env,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b'Cannot fingerprint loaded module Gone.pm',result.stderr)
        self.assertFalse(dest.exists())

    def test_fresh_wrapper_evidence_and_pipeline_status(self):
        script = Path(__file__).with_name('fresh.sh')
        bin_dir = self.root/'bin'; bin_dir.mkdir()
        # Exercise the real shell pipeline without installing dependencies or
        # requiring CPAN access. Only the external installer/runner are fixtures.
        for name, body in {
            'id': 'echo 1000',
            'cpanm': 'echo "fixture cpanm version"',
            'python3': 'printf "%s\\n" "$@"; exit "$FIXTURE_EXIT"',
        }.items():
            p = bin_dir/name; p.write_text('#!/bin/sh\n'+body+'\n'); p.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir)+os.pathsep+os.environ['PATH'])
        for code in (0, 2, 3):
            dest=self.root/('fresh-'+str(code))
            result=subprocess.run(['bash',str(script),str(dest)],env=dict(env,FIXTURE_EXIT=str(code)),
                                  capture_output=True)
            self.assertEqual(result.returncode,code,result.stderr.decode())
            self.assertIn('SOURCE_COMMIT=',(dest/'platform.txt').read_text())
            log=(dest/'qualification.log').read_text()
            self.assertIn('--provision\n--lane\nfull\n',log)
            self.assertIn(str(dest/'result'),log)
            before=(dest/'qualification.log').read_bytes()
            again=subprocess.run(['bash',str(script),str(dest)],env=dict(env,FIXTURE_EXIT='0'),
                                 capture_output=True)
            self.assertNotEqual(again.returncode,0)
            self.assertEqual((dest/'qualification.log').read_bytes(),before)
        (bin_dir/'id').write_text('#!/bin/sh\necho 0\n')
        root_dest=self.root/'root-refused'
        result=subprocess.run(['bash',str(script),str(root_dest)],env=env,capture_output=True)
        self.assertEqual(result.returncode,3)
        self.assertFalse(root_dest.exists())

if __name__=='__main__':unittest.main()
