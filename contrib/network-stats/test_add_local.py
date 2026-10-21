"""Managed hub extension: real HTTP/history plus isolated systemd/Apache operations."""
import copy
from contextlib import ExitStack, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit
from urllib.request import urlopen

import add_local as addition
import network_stats as core
import setup as deploy


class LocalStreamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        paths = {name: self.root / name.lower() for name in
                 ('APP', 'ETC', 'APACHE_ROOT', 'UNITS', 'BACKUPS', 'PUBLISHER_DATA')}
        for p in paths.values():
            p.mkdir(mode=0o700)
        paths['INCLUDE'] = paths['APACHE_ROOT'] / 'stats.conf'
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        for name, path in paths.items():
            self.stack.enter_context(patch.object(deploy, name, path))
        self.stack.enter_context(patch.object(deploy.os, 'chown'))
        identity = types.SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid())
        self.stack.enter_context(patch.object(addition.pwd, 'getpwnam', return_value=identity))
        self.values = {s: secrets.token_urlsafe(36) for s in ('mbdev', 'epiknet')}
        self.cfg = dict(bind='127.0.0.1', port=9409,
                        database=str(self.root / 'history.sqlite3'),
                        streams={s: dict(label=s, token_sha256=hashlib.sha256(v.encode()).hexdigest())
                                 for s, v in self.values.items()})
        self.hub = deploy.ETC / 'hub.json'
        self.hub.write_bytes(core.encode(self.cfg))
        self.hub.chmod(0o640)
        deploy.INCLUDE.write_text(deploy.proxy(self.cfg['streams']))
        (deploy.UNITS / addition.HUB).write_text(deploy.unit_hub())
        shutil.copyfile(deploy.HERE / 'network_stats.py', deploy.APP / 'network_stats.py')
        self.vhost = deploy.APACHE_ROOT / 'site.conf'
        self.vhost.write_text('<VirtualHost *:443>\nServerName teuk.org\n'
                              'Include /etc/apache2/mediabot-network-stats.conf\n</VirtualHost>\n')
        self.snapshot = self.root / 'mediabot3/var/network-stats.json'
        self.snapshot.parent.mkdir(parents=True)
        self.oldfiles = {}
        for stream, value_for_publisher in self.values.items():
            path = deploy.ETC / (stream + '.publisher.json')
            pc = {'url': 'https://teuk.org/network-stats-api/ingest/' + stream,
                  'token': value_for_publisher, 'snapshot': '/private/' + stream,
                  'state': str(deploy.PUBLISHER_DATA / (stream + '.sqlite3'))}
            path.write_bytes(core.encode(pc))
            path.chmod(0o600)
            self.oldfiles[path] = path.read_bytes()
            outbox = deploy.PUBLISHER_DATA / (stream + '.sqlite3')
            with sqlite3.connect(outbox) as db:
                db.execute('CREATE TABLE marker (value TEXT)')
                db.execute('INSERT INTO marker VALUES (?)', (stream,))
        self.server = core.Server(('127.0.0.1', 0), copy.deepcopy(self.cfg))
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.01}, daemon=True)
        self.thread.start()
        def close_server():
            self.server.shutdown()
            self.server.server_close()
            self.thread.join(timeout=3)
        self.addCleanup(close_server)
        for stream in self.values:
            self.server.history.ingest(stream, [self.sample(stream)])
        self.calls = []
        self.states = {addition.HUB: True}
        self.reject_new = False
        self.reject_units = False
        def command(args, capture=False):
            self.calls.append(args)
            if args[0] == 'hostname':
                return 'teuk.org'
            if args[0] == 'systemd-analyze' and self.reject_units:
                raise subprocess.CalledProcessError(7, args)
            if args[:2] == ['systemctl', 'restart'] and args[2] == addition.HUB:
                self.server.cfg = core.load_config(self.hub, 'hub')
            if args[:3] == ['systemctl', 'enable', '--now']:
                self.states[args[3]] = True
            return ''
        self.command = command
        def response(url, timeout):
            if self.reject_new and url.startswith('https:') and '/undernet/data?' in url:
                raise OSError('simulated public TLS/proxy failure')
            u = urlsplit(url)
            return urlopen('http://127.0.0.1:' + str(self.server.server_port) + u.path +
                           ('?' + u.query if u.query else ''), timeout=timeout)
        self.stack.enter_context(patch.object(deploy, 'run', side_effect=command))
        self.stack.enter_context(patch.object(addition, 'urlopen', side_effect=response))
        self.stack.enter_context(patch.object(addition, 'active', side_effect=lambda unit, enabled=False: self.states.get(unit, False)))
        def recovery(args, **kwargs):
            command(args)
            if args[:2] in (['systemctl', 'stop'], ['systemctl', 'disable']):
                self.states[args[2]] = False
            return types.SimpleNamespace(returncode=0)
        self.stack.enter_context(patch.object(addition.subprocess, 'run', side_effect=recovery))

    def sample(self, network='Undernet'):
        return dict(schema=1, sampled_at=int(time.time()) - 3, network=network, interval=300,
                    counts=dict(users=100, visible_users=25, invisible_users=75, channels=20, operators=4))

    def plan(self, **kwargs):
        args = dict(instance='undernet', label='Undernet', snapshot=self.snapshot,
                    site='https://teuk.org', vhost=self.vhost)
        args.update(kwargs)
        with redirect_stdout(io.StringIO()):
            return addition.prepare(**args)

    def retained(self):
        current = core.load_config(self.hub, 'hub')
        for stream in self.values:
            self.assertEqual(current['streams'][stream], self.cfg['streams'][stream])
            self.assertEqual(self.server.history.query(stream, '1h')['samples'], 1)
            with sqlite3.connect(deploy.PUBLISHER_DATA / (stream + '.sqlite3')) as db:
                self.assertEqual(db.execute('SELECT value FROM marker').fetchone()[0], stream)
        for path, raw in self.oldfiles.items():
            self.assertEqual(path.read_bytes(), raw)
        self.assertFalse(any('mediabot@' in str(arg) for cmd in self.calls for arg in cmd))

    def test_preview_has_no_managed_writes_or_service_actions(self):
        original = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file() and 'sqlite' not in p.name}
        self.plan()
        self.assertEqual(original, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file() and 'sqlite' not in p.name})
        self.assertFalse(any(cmd[0] == 'systemctl' for cmd in self.calls))
        self.retained()

    def test_add_roundtrip_retains_streams_tokens_histories_and_outboxes(self):
        output = io.StringIO()
        with redirect_stdout(output):
            addition.install(self.plan())
        self.retained()
        cfg = core.load_config(self.hub, 'hub')
        self.assertEqual(set(cfg['streams']), {'mbdev', 'epiknet', 'undernet'})
        pc = core.load_config(deploy.ETC / 'undernet.publisher.json', 'publisher')
        self.assertEqual(pc['snapshot'], str(self.snapshot))
        self.assertEqual(pc['url'], 'http://127.0.0.1:9409/network-stats-api/ingest/undernet')
        self.assertNotIn(pc['token'], output.getvalue())
        self.assertEqual((deploy.ETC / 'undernet.publisher.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.hub.stat().st_mode & 0o777, 0o640)
        self.snapshot.write_bytes(core.encode(self.sample()))
        class LocalTransport:
            def open(_, request, timeout):
                request.full_url = request.full_url.replace('127.0.0.1:9409', '127.0.0.1:' + str(self.server.server_port))
                return urlopen(request, timeout=timeout)
        self.assertEqual(core.publish(pc, opener=LocalTransport()), 1)
        self.assertEqual(self.server.history.query('undernet', '1h')['latest']['network'], 'Undernet')
        self.assertEqual(self.server.history.query('mbdev', '1h')['latest']['network'], 'mbdev')
        state = self.hub.read_bytes()
        restarts = sum(c == ['systemctl', 'restart', addition.HUB] for c in self.calls)
        with redirect_stdout(io.StringIO()):
            addition.install(self.plan())
        self.assertEqual(self.hub.read_bytes(), state)
        self.assertEqual(sum(c == ['systemctl', 'restart', addition.HUB] for c in self.calls), restarts)

    def test_public_failure_restores_configuration_and_preserves_old_data(self):
        original = (self.hub.read_bytes(), deploy.INCLUDE.read_bytes(), self.vhost.read_bytes())
        self.reject_new = True
        with redirect_stdout(io.StringIO()), self.assertRaises(OSError):
            addition.install(self.plan())
        self.assertEqual((self.hub.read_bytes(), deploy.INCLUDE.read_bytes(), self.vhost.read_bytes()), original)
        self.assertFalse((deploy.ETC / 'undernet.publisher.json').exists())
        self.assertFalse((deploy.UNITS / 'mediabot-network-publish-undernet.timer').exists())
        self.assertEqual(set(self.server.cfg['streams']), {'mbdev', 'epiknet'})
        self.retained()

    def test_unit_validation_failure_restores_all_files_before_hub_restart(self):
        self.reject_units = True
        original = self.hub.read_bytes()
        with redirect_stdout(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
            addition.install(self.plan())
        self.assertEqual(self.hub.read_bytes(), original)
        self.assertFalse((deploy.ETC / 'undernet.publisher.json').exists())
        self.retained()

    def test_failed_recovery_restart_is_reported_as_incomplete(self):
        plan = self.plan()
        self.reject_new = True
        def incomplete(args, **kwargs):
            if args == ['systemctl', 'restart', addition.HUB]:
                return types.SimpleNamespace(returncode=4)
            self.command(args)
            return types.SimpleNamespace(returncode=0)
        output = io.StringIO()
        with patch.object(addition.subprocess, 'run', side_effect=incomplete):
            with redirect_stdout(output), self.assertRaises(OSError):
                addition.install(plan)
        self.assertIn('Recovery requires local inspection', output.getvalue())
        self.assertNotIn('Managed files restored;', output.getvalue())

    def test_rejects_changed_managed_routes(self):
        deploy.INCLUDE.write_text(deploy.INCLUDE.read_text() + '# operator edit\n')
        with self.assertRaises(ValueError):
            self.plan()

    def test_rejects_symbolic_new_publisher_path(self):
        outside = self.root / 'outside'; outside.write_text('retain')
        (deploy.ETC / 'undernet.publisher.json').symlink_to(outside)
        with self.assertRaises(ValueError):
            self.plan()
        self.assertEqual(outside.read_text(), 'retain')

    def test_rejects_invalid_reserved_and_separator_stream_names(self):
        for name in ('../bad', 'x=../bad', 'network-stats-api', 'network-stats-assets'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.plan(instance=name)

    def test_rejects_directory_or_relative_snapshot(self):
        for path in (self.snapshot.parent, Path('var/network-stats.json')):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.plan(snapshot=path)

    def test_concurrent_hub_edit_is_retained(self):
        plan = self.plan()
        changed = copy.deepcopy(self.cfg); changed['streams']['mbdev']['label'] = 'operator edit'
        self.hub.write_bytes(core.encode(changed))
        with self.assertRaises(ValueError):
            addition.install(plan)
        self.assertEqual(core.load_config(self.hub, 'hub'), changed)

    def test_existing_stream_cannot_be_rebound_to_dev_snapshot(self):
        with redirect_stdout(io.StringIO()):
            addition.install(self.plan())
        with self.assertRaises(ValueError):
            self.plan(snapshot=self.root / 'mediabot_v3/var/network-stats.json')


if __name__ == '__main__':
    unittest.main()
