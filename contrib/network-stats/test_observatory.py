"""All-sample statistics, missing values, remote stream and upgrade regressions."""
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import network_stats as n
import setup as deploy
import add_local
import test_add_local
import upgrade
import activate_export
import types


class AnalysisTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.history=n.History(Path(self.tmp.name)/'history.sqlite3');self.now=1780000000
    def put(self,t,counts,interval=300):
        self.history.ingest('libera',[dict(schema=1,sampled_at=t,network='Libera',interval=interval,counts=counts)],self.now)
    def test_statistics_use_all_samples_and_preserve_zero_and_unknown(self):
        for i,v in enumerate([0,10,30,20]):
            counts={'users':v,'channels':0}
            if i!=1:counts['operators']=i
            self.put(self.now-1200+i*300,counts)
        q=self.history.query('libera','1h',self.now);s=q['summary']['users']
        self.assertEqual((s['first'],s['last'],s['delta'],s['delta_percent']),(0,20,20,None))
        self.assertEqual((s['min'],s['max'],s['mean'],s['median'],s['p95'],s['stddev']),(0,30,15,15,30,11.18))
        self.assertEqual(s['max_at'],self.now-600)
        self.assertEqual(q['summary']['operators']['n'],3)
        self.assertNotIn('servers',q['summary'])
        self.assertEqual(q['summary']['channels']['max'],0)
    def test_bucket_summaries_retain_spike_not_in_last_value(self):
        # Both observations share one 90-day display bucket; the peak must
        # remain in the raw summary even when the last display sample is low.
        self.put(self.now-900,{'users':100})
        self.put(self.now-899,{'users':10000})
        self.put(self.now-898,{'users':90})
        q=self.history.query('libera','90d',self.now)
        self.assertEqual(q['samples'],3)
        self.assertEqual(q['summary']['users']['max'],10000)
        self.assertEqual(q['summary']['users']['delta'],-10)
        self.assertEqual(q['summary']['users']['delta_percent'],-10)
        self.assertLess(len(q['points']),q['samples'])
    def test_long_history_preserves_bounds_and_exact_statistics(self):
        # Long-range graphs stay bounded and retain actual samples, while
        # statistics must include every raw measurement and the true peak.
        rows=[]
        for i in range(2000):
            counts={'users':100+i%17,'channels':i%31}
            rows.append(('libera',self.now-i*300,'Libera',300,n.encode(counts).decode()))
        with self.history.connect() as db:
            db.executemany('INSERT INTO samples VALUES (?,?,?,?,?)',rows)
        q=self.history.query('libera','90d',self.now)
        self.assertEqual(q['samples'],2000)
        self.assertLessEqual(len(q['points']),601)
        self.assertEqual(q['summary']['users']['max'],116)
        self.assertEqual(q['points'][-1]['counts']['users'],100)
        self.assertEqual(q['points'][-1]['ts'],self.now)
    def test_net_rate_uses_previous_raw_sample_on_long_range(self):
        self.put(self.now-900,{'users':100})
        self.put(self.now-600,{'users':130})
        self.put(self.now-300,{'users':120})
        q=self.history.query('libera','90d',self.now)
        self.assertGreater(q['bucket_seconds'],750)
        self.assertEqual(q['points'][-1]['net_rate'],-120)
        self.assertLess(len(q['points']),3)
    def test_raw_gap_survives_coarse_display_buckets(self):
        start=self.now-n.RANGES['90d']
        # A gap shorter than one display bucket must still break the curve.
        self.put(start+10000,{'users':100})
        self.put(start+13000,{'users':110})
        self.put(start+13300,{'users':120})
        q=self.history.query('libera','90d',self.now)
        self.assertEqual(len(q['points']),2)
        self.assertEqual(q['points'][-1]['net_rate'],120)
        self.assertTrue(q['points'][-1]['gap_before'])
        self.assertEqual(q['quality']['gaps'],1)
    def test_coverage_merges_overlaps_and_clips_unfinished_slot(self):
        self.put(self.now-900,{'users':100},600)
        self.put(self.now-600,{'users':100},600)
        self.put(self.now-100,{'users':100},300)
        q=self.history.query('libera','1h',self.now)['quality']
        self.assertEqual(q['covered_seconds'],900)
        self.assertEqual(q['coverage_percent'],25)
        self.assertEqual(q['gaps'],0)
        self.assertEqual(q['sample_intervals'],[300,600])
    def test_gaps_and_empty_period_are_not_network_uptime(self):
        self.put(self.now-3300,{'users':100})
        self.put(self.now-300,{'users':100})
        q=self.history.query('libera','1h',self.now)['quality']
        self.assertEqual((q['covered_seconds'],q['gaps'],q['longest_gap_seconds']),(600,1,3000))
        empty=self.history.query('other','1h',self.now)
        self.assertEqual(empty['quality']['coverage_percent'],0)
        self.assertIsNone(empty['quality']['first_at'])
        self.assertEqual(empty['summary'],{})
    def test_statistics_serialize_without_nonfinite_or_private_fields(self):
        self.put(self.now,{'users':0})
        raw=n.encode(self.history.query('libera','1h',self.now)).decode()
        self.assertNotIn('NaN',raw);self.assertNotIn('Infinity',raw)
        self.assertNotIn('token',raw)


class ProvisionTest(unittest.TestCase):
    def setUp(self):
        self.fixture=test_add_local.LocalStreamTest('test_preview_has_no_managed_writes_or_service_actions')
        self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.fixture.stack.enter_context(patch.object(deploy,'BOT_HOME',self.fixture.root))
    def plan(self):
        with redirect_stdout(io.StringIO()):
            return add_local.prepare('libera','Libera',Path('/home/mediabot/mediabot_v3/var/network-stats.json'),
                                     'https://teuk.org',self.fixture.vhost,'mediabot.teuk.org')
    def test_remote_add_is_private_host_bound_additive_and_idempotent(self):
        f=self.fixture;original=f.hub.read_bytes();p=self.plan();self.assertEqual(f.hub.read_bytes(),original)
        output=io.StringIO()
        with redirect_stdout(output):add_local.install(p)
        f.retained();pc=n.load_config(p['publisher'],'publisher')
        self.assertEqual(pc['url'],'https://teuk.org/network-stats-api/ingest/libera')
        self.assertEqual(pc['publisher_host'],'mediabot.teuk.org')
        self.assertNotIn(pc['token'],output.getvalue())
        self.assertEqual(p['publisher'].stat().st_mode&0o777,0o600)
        self.assertFalse((deploy.ETC/'libera.publisher.json').exists())
        self.assertFalse((deploy.UNITS/'mediabot-network-publish-libera.timer').exists())
        self.assertFalse(any('libera.timer' in str(c) for c in f.calls))
        after=f.hub.read_bytes();praw=p['publisher'].read_bytes();calls=len(f.calls)
        with redirect_stdout(io.StringIO()):add_local.install(self.plan())
        self.assertEqual(f.hub.read_bytes(),after);self.assertEqual(p['publisher'].read_bytes(),praw)
        self.assertFalse(any(c[:2]==['systemctl','restart'] for c in f.calls[calls:]))
    def test_remote_host_mismatch_rejected_before_install(self):
        with redirect_stdout(io.StringIO()):add_local.install(self.plan())
        p=self.plan()
        args=['setup.py','publisher','--instance','libera','--publisher-config',str(p['publisher']),'--apply']
        with patch('sys.argv',args),patch.object(deploy,'run',return_value='wrong.teuk.org'):
            with self.assertRaisesRegex(ValueError,'another host'):deploy.main()
        self.assertFalse((deploy.ETC/'libera.publisher.json').exists())
    def test_remote_binding_missing_credential_and_invalid_host_refused(self):
        with self.assertRaisesRegex(ValueError,'hostname'):
            add_local.prepare('libera','Libera',Path('/home/mediabot/snapshot.json'),'https://teuk.org',self.fixture.vhost,'x;touch /tmp/oops')
        with redirect_stdout(io.StringIO()):add_local.install(self.plan())
        p=self.plan();p['publisher'].unlink()
        with self.assertRaises(ValueError):self.plan()
    def test_failed_remote_public_endpoint_rolls_back_new_files_only(self):
        f=self.fixture;original=f.hub.read_bytes();p=self.plan();check=add_local.checked_json
        def fail(url,stream=None):
            if stream=='libera':raise OSError('isolated public route error')
            return check(url,stream)
        with patch.object(add_local,'checked_json',side_effect=fail),redirect_stdout(io.StringIO()):
            with self.assertRaises(OSError):add_local.install(p)
        self.assertEqual(f.hub.read_bytes(),original);self.assertFalse(p['publisher'].exists());f.retained()
    def upgrade_plan(self):
        f=self.fixture
        for rel in upgrade.PREVIOUS:
            dest=deploy.APP/rel;dest.parent.mkdir(parents=True,exist_ok=True)
            dest.write_bytes((deploy.HERE/rel).read_bytes())
        with redirect_stdout(io.StringIO()):return upgrade.prepare('https://teuk.org',f.vhost)
    def test_current_ui_upgrade_is_idempotent_without_service_restart(self):
        p=self.upgrade_plan();f=self.fixture;calls=len(f.calls)
        with redirect_stdout(io.StringIO()):upgrade.install(p)
        self.assertFalse(any(c[:2]==['systemctl','restart'] for c in f.calls[calls:]));f.retained()
    def changed_upgrade(self):
        self.upgrade_plan()
        old=dict(upgrade.PREVIOUS)
        for rel in old:
            path=deploy.APP/rel;path.write_bytes(b'reviewed previous fixture\n')
            old[rel]=hashlib.sha256(path.read_bytes()).hexdigest()
        return old
    def test_ui_upgrade_retains_hub_credentials_and_all_history(self):
        f=self.fixture;old=self.changed_upgrade();hub=f.hub.read_bytes();routes=deploy.INCLUDE.read_bytes()
        with patch.object(upgrade,'PREVIOUS',old),redirect_stdout(io.StringIO()):
            p=upgrade.prepare('https://teuk.org',f.vhost);upgrade.install(p)
        self.assertEqual(f.hub.read_bytes(),hub);self.assertEqual(deploy.INCLUDE.read_bytes(),routes)
        for rel in old:self.assertEqual((deploy.APP/rel).read_bytes(),(deploy.HERE/rel).read_bytes())
        f.retained()
    def test_failed_ui_upgrade_restores_code_without_changing_data(self):
        f=self.fixture;old=self.changed_upgrade();before={rel:(deploy.APP/rel).read_bytes() for rel in old}
        real=add_local.checked_json;count=[0]
        def fail(url,stream=None):
            if stream=='epiknet':
                count[0]+=1
                if count[0]>1:raise OSError('public route lost')
            return real(url,stream)
        with patch.object(upgrade,'PREVIOUS',old),patch.object(add_local,'checked_json',side_effect=fail),redirect_stdout(io.StringIO()):
            p=upgrade.prepare('https://teuk.org',f.vhost)
            with self.assertRaises(OSError):upgrade.install(p)
        for rel,raw in before.items():self.assertEqual((deploy.APP/rel).read_bytes(),raw)
        f.retained()
    def test_upgrade_refuses_unreviewed_installed_code(self):
        self.upgrade_plan();(deploy.APP/'static/dashboard.js').write_text('operator custom change')
        with self.assertRaisesRegex(ValueError,'differs from reviewed'):
            upgrade.prepare('https://teuk.org',self.fixture.vhost)


class ExportActivationTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.bot=self.root/'bot';self.bot.mkdir()
        self.config=self.bot/'mediabot.conf'
        self.config.write_text('[connection]\nCONN_SERVER_NETWORK=Libera.Chat\n[main]\nMAIN_PROG_LANG=en\n[meta_ai]\nENABLED=0\n')
        self.before=self.config.read_bytes();self.fake=self.root/'12345';self.fake.mkdir()
        (self.fake/'cgroup').write_text('0::/system.slice/mediabot@libera.service\n')
    def test_conf_argument_forms_and_exact_unit_owner(self):
        target=self.config
        self.assertTrue(activate_export.conf_args([b'perl',b'--conf='+os.fsencode(target)],target))
        self.assertTrue(activate_export.conf_args([b'--conf',os.fsencode(target)],target))
        self.assertFalse(activate_export.conf_args([b'--conf='+os.fsencode(str(target)+'.other')],target))
        who=__import__('pwd').getpwuid(os.getuid()).pw_name
        with patch.object(activate_export,'command',return_value='MainPID=12345\nActiveState=active\nUser='+who):
            self.assertEqual(activate_export.managed_unit(self.fake,os.getuid()),'mediabot@libera.service')
        with patch.object(activate_export,'command',return_value='MainPID=67890\nActiveState=active\nUser='+who):
            with self.assertRaises(ValueError):activate_export.managed_unit(self.fake,os.getuid())
    def activate(self,fail=False):
        real=subprocess.run;calls=[];starts=[0]
        def run(args,**kwargs):
            if args[0]=='perl':return real(args,**kwargs)
            calls.append(args)
            if args[:4]==['sudo','-n','systemctl','start']:
                starts[0]+=1
                if fail and starts[0]==1:raise subprocess.CalledProcessError(3,args)
            return types.SimpleNamespace(returncode=0)
        a=types.SimpleNamespace(instance='libera',site_url='https://teuk.org')
        plan=(self.bot,self.config,self.bot/'var/network-stats.json','mediabot@libera.service','12345')
        with patch.object(activate_export,'process',return_value=self.fake),patch.object(activate_export,'managed_unit',return_value=plan[3]),patch.object(activate_export.subprocess,'run',side_effect=run),redirect_stdout(io.StringIO()):
            activate_export.activate(a,plan)
        return calls
    def test_native_writer_changes_only_three_fields_and_one_verified_unit(self):
        # Native Mediabot::Conf is loaded from the actual source checkout.
        repo=Path(__file__).resolve().parents[2]
        os.symlink(repo/'Mediabot',self.bot/'Mediabot',target_is_directory=True)
        calls=self.activate()
        conf=activate_export.configured_network(self.bot,self.config)
        self.assertEqual(conf,'Libera.Chat')
        self.assertIn('OUTPUT_FILE',self.config.read_text())
        self.assertIn('ENABLED=0',self.config.read_text().replace(' ',''))
        self.assertTrue(all(c[-1]=='mediabot@libera.service' for c in calls))
    def test_failed_restart_restores_private_configuration(self):
        repo=Path(__file__).resolve().parents[2]
        os.symlink(repo/'Mediabot',self.bot/'Mediabot',target_is_directory=True)
        with self.assertRaises(subprocess.CalledProcessError):self.activate(fail=True)
        self.assertEqual(self.config.read_bytes(),self.before)


if __name__=='__main__':unittest.main()
