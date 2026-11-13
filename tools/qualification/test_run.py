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
                           'install/cpan_install.sh':'exit 0\n'}.items():
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
        for lane,expected in [('preflight',2),('fast',3),('full',3)]:
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
        with patch.object(q,'run_stage',side_effect=[{'status':'passed'},{'status':'passed'},{'status':'failed','returncode':7}]):
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

if __name__=='__main__':unittest.main()
