#!/usr/bin/env python3
"""Add one local publisher/dashboard to an existing managed statistics hub.

Default: read-only plan. No bot restart or private bot configuration change.
Existing stream credentials, publisher files and SQLite history are retained.
"""
import argparse
import copy
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import pwd
import secrets
import subprocess
import tempfile
import time
from urllib.request import urlopen

import network_stats as core
import setup as deploy

HUB = 'mediabot-network-stats.service'


def safe(path):
    path = Path(path)
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('symbolic managed path refused')
    return path


def active(unit, enabled=False):
    return subprocess.run(['systemctl', 'is-enabled' if enabled else 'is-active',
                           '--quiet', unit], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def checked_json(url, stream=None):
    with urlopen(url, timeout=10) as response:
        raw = response.read(core.MAX_BODY + 1)
        if response.status != 200 or len(raw) > core.MAX_BODY:
            raise ValueError('dashboard health check failed')
        value = core.strict_json(raw)
        if not isinstance(value, dict):
            raise ValueError('invalid dashboard health response')
        if stream is None:
            if value.get('ok') is not True:
                raise ValueError('hub is not healthy')
        elif value.get('stream') != stream or not isinstance(value.get('points'), list):
            raise ValueError('public stream check failed')


def prepare(instance, label, snapshot, site, vhost, remote_host=None):
    if not core.SLUG.fullmatch(instance) or instance in ('network-stats-api', 'network-stats-assets'):
        raise ValueError('invalid or reserved stream instance')
    host, _, _ = deploy.profile(site, [instance + '=' + label], instance)
    if host == 'teuk.org' and deploy.run(['hostname', '-f'], True) != host:
        raise ValueError('teuk.org profile expects that host')
    if remote_host is not None and not deploy.valid_host(remote_host):
        raise ValueError('invalid remote publisher hostname')
    snapshot = Path(snapshot) if remote_host else safe(snapshot)
    if not snapshot.is_absolute() or '..' in snapshot.parts or (not remote_host and snapshot.exists() and not snapshot.is_file()):
        raise ValueError('snapshot must be an absolute regular-file path')
    hubpath = safe(deploy.ETC / 'hub.json')
    cfg = core.load_config(hubpath, 'hub')
    if cfg.get('bind', '127.0.0.1') != '127.0.0.1' or cfg.get('port', 9409) != 9409:
        raise ValueError('expected the existing managed loopback hub on port 9409')
    if not active(HUB):
        raise ValueError('existing hub must be active')
    if safe(deploy.UNITS / HUB).read_text() != deploy.unit_hub():
        raise ValueError('hub unit differs from the managed installation')
    if safe(deploy.APP / 'network_stats.py').read_bytes() != (deploy.HERE / 'network_stats.py').read_bytes():
        raise ValueError('installed hub implementation differs; review its deployment first')
    target = Path(vhost).resolve(strict=True)
    if deploy.APACHE_ROOT not in target.parents:
        raise ValueError('expected Apache configuration path')
    text = target.read_text()
    if deploy.vhost_include(text, host) != text:
        raise ValueError('selected TLS vhost does not include the managed statistics routes')
    include = safe(deploy.INCLUDE)
    if include.read_text() != deploy.proxy(cfg['streams']):
        raise ValueError('managed routes differ; review them before extending the hub')
    deploy.run(['apache2ctl', 'configtest'], True)
    checked_json('http://127.0.0.1:9409/network-stats-api/health')
    for stream in cfg['streams']:
        checked_json(site.rstrip('/') + '/' + stream + '/data?range=1h', stream)
    publisher = safe(deploy.BOT_HOME / ('network-stats-' + instance + '.private.json') if remote_host else deploy.ETC / (instance + '.publisher.json'))
    state = safe(deploy.PUBLISHER_DATA / (instance + '.sqlite3'))
    files = {
        safe(deploy.UNITS / ('mediabot-network-publish-' + instance + '.service')): deploy.unit_publisher(instance),
        safe(deploy.UNITS / ('mediabot-network-publish-' + instance + '.timer')): deploy.unit_timer(instance),
    }
    if remote_host:
        files = {}
    url = (site.rstrip('/') if remote_host else 'http://127.0.0.1:9409') + '/network-stats-api/ingest/' + instance
    if instance in cfg['streams']:
        pc = core.load_config(publisher, 'publisher')
        if publisher.stat().st_mode & 0o777 != 0o600:
            raise ValueError('existing publisher configuration must remain private (0600)')
        digest = hashlib.sha256(pc['token'].encode()).hexdigest()
        if (cfg['streams'][instance]['label'] != label
                or not hmac.compare_digest(digest, cfg['streams'][instance]['token_sha256'])
                or (remote_host and pc.get('publisher_host') != remote_host)
                or pc['url'] != url or pc['snapshot'] != str(snapshot) or pc['state'] != str(state)
                or any(not p.is_file() or p.read_text() != content for p, content in files.items())):
            raise ValueError('existing stream does not match the requested local publisher')
        present = True
    else:
        if len(cfg['streams']) >= 16:
            raise ValueError('hub already has sixteen streams')
        if any(p.exists() for p in [publisher, *([] if remote_host else [state]), *files]):
            raise ValueError('new stream has pre-existing managed files or outbox; review recovery first')
        timer = 'mediabot-network-publish-' + instance + '.timer'
        if active(timer) or active(timer, True):
            raise ValueError('new publisher timer already exists outside the reviewed files')
        present = False
    owner = pwd.getpwnam('mediabot')
    directory = safe(deploy.BOT_HOME if remote_host else deploy.PUBLISHER_DATA)
    st = directory.stat()
    if not directory.is_dir() or (st.st_uid, st.st_gid) != (owner.pw_uid, owner.pw_gid) or (not remote_host and st.st_mode & 0o777 != 0o700):
        raise ValueError('existing private publisher directory has unexpected ownership or permissions')
    print('[PLAN] ' + site.rstrip('/') + '/' + instance + ' <- ' + (remote_host + ':' if remote_host else '') + str(snapshot))
    print('[PLAN] Retain existing stream credentials, publisher files and history database. No bot changes.')
    return dict(cfg=cfg, hubpath=hubpath, publisher=publisher, state=state,
                files=files, url=url, snapshot=snapshot, instance=instance,
                label=label, site=site, present=present, remote_host=remote_host, owner=(owner.pw_uid, owner.pw_gid),
                observed={hubpath: hubpath.read_bytes(), include: include.read_bytes()})


def install(plan):
    timer = 'mediabot-network-publish-' + plan['instance'] + '.timer'
    if any(safe(p).read_bytes() != raw for p, raw in plan['observed'].items()):
        raise ValueError('managed configuration changed after preview; rerun the plan')
    if plan['present']:
        if not plan['remote_host']:
            deploy.run(['systemctl', 'enable', '--now', timer])
        print('[OK] Existing stream verified; credentials and history unchanged.')
        return
    cfg = copy.deepcopy(plan['cfg'])
    value_for_publisher = secrets.token_urlsafe(36)
    cfg['streams'][plan['instance']] = {
        'label': plan['label'],
        'token_sha256': hashlib.sha256(value_for_publisher.encode()).hexdigest(),
    }
    pc = dict(url=plan['url'], token=value_for_publisher,
              snapshot=str(plan['snapshot']), state=str(plan['state']))
    if plan['remote_host']:
        pc['publisher_host'] = plan['remote_host']
    st = plan['hubpath'].stat()
    files = {
        plan['hubpath']: (core.encode(cfg), st.st_mode & 0o777, (st.st_uid, st.st_gid)),
        deploy.INCLUDE: (deploy.proxy(cfg['streams']).encode(), 0o644, (0, 0)),
        plan['publisher']: (core.encode(pc), 0o600, plan['owner']),
        **{p: (text.encode(), 0o644, (0, 0)) for p, text in plan['files'].items()},
    }
    if any(p.exists() for p in [plan['publisher'], *([] if plan['remote_host'] else [plan['state']]), *plan['files']]):
        raise ValueError('new publisher files appeared after preview; no changes made')
    backup = Path(tempfile.mkdtemp(prefix='mediabot-network-add-local-', dir=deploy.BACKUPS))
    os.chmod(backup, 0o700)
    prior = {}
    for index, path in enumerate(files):
        safe(path)
        if path.exists():
            state = path.stat()
            raw = path.read_bytes()
            prior[path] = (raw, state.st_mode & 0o777, (state.st_uid, state.st_gid))
            deploy.atomic(backup / str(index), raw, 0o600)
        else:
            prior[path] = None
    deploy.atomic(backup / 'paths.json', core.encode([str(p) for p in files]), 0o600)
    print('[BACKUP] ' + str(backup))
    try:
        for path, (content, mode, owner) in files.items():
            deploy.atomic(path, content, mode, owner)
        if plan['files']:
            deploy.run(['systemd-analyze', 'verify', *(str(p) for p in plan['files'])], True)
        deploy.run(['apache2ctl', 'configtest'], True)
        if not plan['remote_host']:
            deploy.run(['runuser', '-u', 'mediabot', '--', '/usr/bin/python3', '-B',
                        str(deploy.APP / 'network_stats.py'), 'check', '--config', str(plan['publisher'])], True)
        deploy.run(['systemctl', 'daemon-reload'])
        deploy.run(['systemctl', 'restart', HUB])
        for attempt in range(20):
            try:
                checked_json('http://127.0.0.1:9409/network-stats-api/health')
                break
            except OSError:
                if attempt == 19:
                    raise
                time.sleep(.25)
        deploy.run(['systemctl', 'reload', 'apache2'])
        for stream in cfg['streams']:
            checked_json(plan['site'].rstrip('/') + '/' + stream + '/data?range=1h', stream)
        if not plan['remote_host']:
            deploy.run(['systemctl', 'enable', '--now', timer])
    except Exception:
        incomplete = False
        for action in (() if plan['remote_host'] else ('stop', 'disable')):
            subprocess.run(['systemctl', action, timer], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for path, original in prior.items():
            if path.is_symlink() or (path.exists() and path.read_bytes() not in
                                    (files[path][0], original[0] if original else None)):
                print('[RECOVERY] Concurrent edit retained; original files are in ' + str(backup))
                incomplete = True
                continue
            try:
                if original is None:
                    path.unlink(missing_ok=True)
                else:
                    deploy.atomic(path, *original)
            except OSError:
                incomplete = True
        for command in (['systemctl', 'daemon-reload'], ['systemctl', 'restart', HUB],
                        ['apache2ctl', 'configtest'], ['systemctl', 'reload', 'apache2']):
            result = subprocess.run(command, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                incomplete = True
        if incomplete:
            print('[RECOVERY] Recovery requires local inspection; original managed files: ' + str(backup))
        else:
            print('[RECOVERY] Managed files restored; existing histories and publisher outboxes retained.')
        raise
    print('[OK] Stream added: ' + plan['site'].rstrip('/') + '/' + plan['instance'])
    if plan['remote_host']:
        print('[NEXT] Transfer the private file over SSH to ' + plan['remote_host'] + ': ' + str(plan['publisher']))
    print('[NEXT] Enable the matching bot export through its real configuration, then check a fresh sample.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', required=True)
    parser.add_argument('--label', required=True)
    parser.add_argument('--snapshot', required=True, type=Path)
    parser.add_argument('--apache-vhost', required=True, type=Path)
    parser.add_argument('--site-url', default='https://teuk.org')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    def plan():
        return prepare(args.instance, args.label, args.snapshot, args.site_url, args.apache_vhost)
    if not args.apply:
        plan()
        print('[OK] Read-only plan; add --apply to extend the existing hub.')
        return
    if os.geteuid() != 0:
        raise ValueError('installation requires sudo -n python3 add_local.py ... --apply')
    fd = os.open(safe(deploy.ETC / 'add-local.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install(plan())


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(deploy.failure_message(error))
        raise SystemExit(1)
