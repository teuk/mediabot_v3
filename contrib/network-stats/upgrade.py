#!/usr/bin/env python3
"""Upgrade only the existing statistics hub code and UI, retaining all streams.
Read-only by default; no credentials, routes, bot units or publisher timers edited.
"""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import time
import add_local as guard
import network_stats as core
import setup as deploy

# The shipped pre-MB831 implementation/assets, reviewed from the supplied tree.
PREVIOUS = {'network_stats.py': '6fbedbc0299c769e5fbbd7e76940c5af3c9af041408195e1d7534b5a8c78e356', 'static/index.html': '8d5553a5a5361ff1c19ca958cef0651ba0305517175df9bb831386c54da38385', 'static/dashboard.css': '2dd862abcdcb1bb231e44bbf58e9fc4cdbc96c9fa9f4b9fe7bf27d3cabb6417c', 'static/dashboard.js': 'eaafef46584dc343ce221f8d8853ab45686e95864d830bafd7d7acece2cd9e40'}


def prepare(site, vhost):
    host,_,_=deploy.profile(site,['review=Review'],'review')
    if host=='teuk.org' and deploy.run(['hostname','-f'],True)!=host:
        raise ValueError('teuk.org profile expects that host')
    if not guard.active(guard.HUB):raise ValueError('existing hub must be active')
    cfg=core.load_config(guard.safe(deploy.ETC/'hub.json'),'hub')
    if cfg.get('bind','127.0.0.1')!='127.0.0.1' or cfg.get('port',9409)!=9409:
        raise ValueError('expected managed loopback hub on 9409')
    if guard.safe(deploy.UNITS/guard.HUB).read_text()!=deploy.unit_hub():
        raise ValueError('existing hub unit differs from the managed installation')
    target=Path(vhost).resolve(strict=True)
    if deploy.APACHE_ROOT not in target.parents or deploy.vhost_include(target.read_text(),host)!=target.read_text():
        raise ValueError('expected the existing managed TLS vhost include')
    if guard.safe(deploy.INCLUDE).read_text()!=deploy.proxy(cfg['streams']):
        raise ValueError('existing managed routes differ; review before upgrading')
    deploy.run(['apache2ctl','configtest'],True)
    guard.checked_json('http://127.0.0.1:9409/network-stats-api/health')
    for slug in cfg['streams']:guard.checked_json(site.rstrip('/')+'/'+slug+'/data?range=1h',slug)
    files={}
    for rel,previous in PREVIOUS.items():
        source=guard.safe(deploy.HERE/rel);dest=guard.safe(deploy.APP/rel)
        old=dest.read_bytes();new=source.read_bytes()
        if hashlib.sha256(old).hexdigest() not in (previous,hashlib.sha256(new).hexdigest()):
            raise ValueError('installed hub file differs from reviewed versions: '+rel)
        files[dest]=(old,new,dest.stat())
    compile((deploy.HERE/'network_stats.py').read_text(),'network_stats.py','exec')
    print('[PLAN] Upgrade dashboard code/assets for: '+', '.join(cfg['streams']))
    print('[PLAN] Keep hub configuration, all stream credentials, routes, history and publisher services unchanged.')
    return cfg,files,{p:p.read_bytes() for p in (deploy.ETC/'hub.json',deploy.INCLUDE,target)},site


def install(plan):
    cfg,files,observed,site=plan
    if any(guard.safe(p).read_bytes()!=v for p,v in observed.items()) or any(p.read_bytes()!=v[0] for p,v in files.items()):
        raise ValueError('managed files changed after preview; no changes made')
    if all(old==new for old,new,_ in files.values()):
        print('[OK] Dashboard is already current; no service restarted.')
        return
    backup=Path(tempfile.mkdtemp(prefix='mediabot-network-upgrade-',dir=deploy.BACKUPS));os.chmod(backup,0o700)
    for path,(old,_,_) in files.items():deploy.atomic(backup/path.relative_to(deploy.APP),old,0o600)
    print('[BACKUP] '+str(backup))
    try:
        for path,(_,new,_) in files.items():deploy.atomic(path,new,0o644,(0,0))
        deploy.run(['systemctl','restart',guard.HUB])
        for attempt in range(20):
            try:guard.checked_json('http://127.0.0.1:9409/network-stats-api/health');break
            except OSError:
                if attempt==19:raise
                time.sleep(.25)
        for slug in cfg['streams']:guard.checked_json(site.rstrip('/')+'/'+slug+'/data?range=1h',slug)
        if any(guard.safe(p).read_bytes()!=v for p,v in observed.items()):
            raise ValueError('managed configuration changed during deployment')
    except Exception:
        incomplete=False
        for path,(old,new,st) in files.items():
            if path.is_symlink() or (path.exists() and path.read_bytes() not in (old,new)):
                incomplete=True;continue
            try:deploy.atomic(path,old,st.st_mode&0o777,(st.st_uid,st.st_gid))
            except OSError:incomplete=True
        result=subprocess.run(['systemctl','restart',guard.HUB],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if result.returncode:incomplete=True
        print('[RECOVERY] '+('Local inspection required; backup: '+str(backup) if incomplete else 'Previous code/assets restored; history and credentials retained.'))
        raise
    print('[OK] Dashboard upgraded for every configured stream; no bot/publisher restart.')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--site-url',default='https://teuk.org')
    p.add_argument('--apache-vhost',required=True,type=Path)
    p.add_argument('--apply',action='store_true')
    a=p.parse_args()
    if not a.apply:
        prepare(a.site_url,a.apache_vhost)
        print('[OK] Read-only upgrade plan; add --apply to install.')
        return
    if os.geteuid()!=0:raise ValueError('installation requires sudo -n python3 upgrade.py ... --apply')
    fd=os.open(guard.safe(deploy.ETC/'add-local.lock'),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        install(prepare(a.site_url,a.apache_vhost))


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(deploy.failure_message(error))
        raise SystemExit(1)
