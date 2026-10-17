#!/usr/bin/env python3
"""Install the network dashboard hub or one publisher. Default: read-only plan."""
import argparse
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shutil
import subprocess
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import urlopen

HERE=Path(__file__).resolve().parent
APP=Path('/opt/mediabot-network-stats')
ETC=Path('/etc/mediabot-network-stats')
DATA=Path('/var/lib/mediabot-network-stats')
INCLUDE=Path('/etc/apache2/mediabot-network-stats.conf')
APACHE_ROOT=Path('/etc/apache2')
UNITS=Path('/etc/systemd/system')
BOT_HOME=Path('/home/mediabot')
BACKUPS=Path('/var/backups')
PUBLISHER_DATA=Path('/var/lib/mediabot-network-stats-publisher')


def run(args,capture=False):
    r=subprocess.run(args,check=True,text=True,stdout=subprocess.PIPE if capture else None,stderr=subprocess.STDOUT if capture else None)
    return r.stdout.strip() if capture else ''


def managed_directory(path,mode,owner):
    path=Path(path)
    if any(p.is_symlink() for p in (path,*path.parents)):
        raise ValueError('symbolic managed directory refused')
    path.mkdir(parents=True,exist_ok=True)
    # mkdir(mode=...) is filtered by the caller's umask. These managed
    # directories must be traversable by their service accounts even at 077.
    os.chmod(path,mode)
    os.chown(path,*owner)


def failure_message(error):
    if isinstance(error,subprocess.CalledProcessError):
        args=error.cmd
        command=Path(str(args[0])).name if isinstance(args,(list,tuple)) and args else 'subprocess'
        command=re.sub('[^A-Za-z0-9_.-]','?',command)[:80]
        # Arguments and captured output may include private configuration.
        return f'[KO] Setup command failed: {command} (exit {error.returncode}); inspect local service/configuration status.'
    if isinstance(error,ValueError):return '[KO] '+str(error)
    return '[KO] Setup failed ('+type(error).__name__+'); inspect local service/configuration status.'


def atomic(path,content,mode=0o644,owner=None):
    path=Path(path)
    if any(x.is_symlink() for x in (path,*path.parents)): raise ValueError('symbolic target refused: '+str(path))
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,name=tempfile.mkstemp(prefix='.network-stats-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as f:f.write(content if isinstance(content,bytes) else content.encode())
        os.chmod(name,mode)
        if owner:os.chown(name,*owner)
        os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)


def vhost_include(text, hostname='teuk.org'):
    """Require one explicit TLS vhost; do not edit an ambiguous multi-vhost file."""
    blocks=list(re.finditer(r'<VirtualHost\b([^>]*)>(.*?)</VirtualHost\s*>',text,re.I|re.S))
    if len(blocks)!=1 or not re.search(r':443\b',blocks[0][1]):
        raise ValueError('select a file containing exactly one TLS :443 VirtualHost')
    if not re.search(r'^\s*ServerName\s+'+re.escape(hostname)+r'\s*$',blocks[0][2],re.M|re.I):
        raise ValueError('expected ServerName '+hostname+' in selected TLS vhost')
    directive='    Include /etc/apache2/mediabot-network-stats.conf'
    if directive.strip() in text:
        return text
    end=text.lower().rindex('</virtualhost')
    return text[:end]+directive+'\n'+text[end:]


def unit_hub():
    return '''[Unit]
Description=Mediabot network history and dashboards
After=network.target
[Service]
Type=exec
User=mbnetstats
Group=mbnetstats
ExecStart=/usr/bin/python3 -B /opt/mediabot-network-stats/network_stats.py serve --config /etc/mediabot-network-stats/hub.json
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/mediabot-network-stats
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
[Install]
WantedBy=multi-user.target
'''


def unit_publisher(slug):
    return f'''[Unit]
Description=Mediabot network stats publisher ({slug})
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
User=mediabot
Group=mediabot
ExecStart=/usr/bin/python3 -B /opt/mediabot-network-stats/network_stats.py publish --config /etc/mediabot-network-stats/{slug}.publisher.json
TimeoutStartSec=25
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/mediabot-network-stats-publisher
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
'''


def unit_timer(slug):
    return f'''[Unit]
Description=Publish Mediabot {slug} network samples every 30 seconds
[Timer]
OnBootSec=20
OnUnitInactiveSec=30
AccuracySec=1
Unit=mediabot-network-publish-{slug}.service
[Install]
WantedBy=timers.target
'''


def proxy(slugs):
    result='# Managed by Mediabot network stats setup; inside the teuk.org TLS vhost.\n'
    for route in [*('/'+s for s in slugs),'/network-stats-api','/network-stats-assets']:
        result+=f'ProxyPassMatch "^({route}(?:/.*)?)$" "http://127.0.0.1:9409$1" timeout=20 connectiontimeout=3\n'
        result+=f'ProxyPassReverse {route} http://127.0.0.1:9409{route}\n'
    return result


def audit():
    print('[PLAN] Dashboard host: teuk.org; publisher host: teuk.org or nbot. No changes.')
    for command in (['hostname','-f'],['systemctl','list-units','--all','--type=service','mediabot*','--no-pager'],['apache2ctl','-S']):
        if shutil.which(command[0]):
            try:print(run(command,True))
            except subprocess.CalledProcessError:print('[INFO] Command unavailable at current privilege: '+command[0])


def profile(site, specs, local):
    u=urlsplit(site)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.path not in ('','/') or u.query or u.fragment or u.port not in (None,443):
        raise ValueError('site URL must be an HTTPS origin')
    if not re.fullmatch('[A-Za-z0-9.-]{1,253}',u.hostname):raise ValueError('invalid site hostname')
    streams={}
    for spec in specs or ['mbdev=Mediabot · Dev','epiknet=EpikNet']:
        slug,sep,label=spec.partition('=')
        if not sep or not re.fullmatch('[a-z][a-z0-9-]{0,39}',slug) or not 1<=len(label)<=80 or any(ord(x)<32 for x in label) or slug in streams:
            raise ValueError('streams must be unique SLUG=LABEL values')
        streams[slug]=label
    if not 1<=len(streams)<=16:raise ValueError('one to sixteen streams required')
    local=local or next(iter(streams))
    if local not in streams:raise ValueError('local instance must be a configured stream')
    return u.hostname,streams,local


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('role',choices=('audit','hub','publisher'))
    p.add_argument('--apache-vhost',type=Path)
    p.add_argument('--instance',default='mbdev')
    p.add_argument('--publisher-config',type=Path)
    p.add_argument('--site-url',default='https://teuk.org')
    p.add_argument('--stream',action='append',help='repeat SLUG=LABEL; defaults to mbdev and epiknet')
    p.add_argument('--local-instance',help='local publisher stream; defaults to first stream')
    p.add_argument('--apply',action='store_true')
    a=p.parse_args()
    if a.role=='audit':return audit()
    if not re.fullmatch('[a-z][a-z0-9-]{0,39}',a.instance):raise ValueError('invalid instance')
    import network_stats as core
    who=pwd.getpwnam('mediabot');med=(who.pw_uid,who.pw_gid)
    cfg=None;target=None
    if a.role=='hub':
        host,streams,local=profile(a.site_url,a.stream,a.local_instance)
        if host=='teuk.org' and run(['hostname','-f'],True)!='teuk.org':raise ValueError('teuk.org profile expects that host')
        if not a.apache_vhost:raise ValueError('--apache-vhost is required; run audit first')
        target=a.apache_vhost.resolve(strict=True)
        if APACHE_ROOT not in target.parents:raise ValueError('expected Apache configuration path')
        vtext=vhost_include(target.read_text(),host)
        run(['apache2ctl','configtest'],True)
        print('[PLAN] Hub: 127.0.0.1:9409; SQLite 90 days; '+', '.join('/'+k for k in streams)+' in '+str(target))
        print('[PLAN] Generate separate stream credentials; local publisher '+local+' and private remote configurations.')
        if (ETC/'hub.json').exists():
            cfg=core.load_config(ETC/'hub.json','hub')
            if set(cfg['streams'])!=set(streams):raise ValueError('existing hub has different streams; retain credentials and review a migration')
        files={UNITS/'mediabot-network-stats.service':unit_hub(),target:vtext,INCLUDE:proxy(streams)}
    else:
        if not a.publisher_config:raise ValueError('--publisher-config must name the private transferred configuration')
        cfg=core.load_config(a.publisher_config,'publisher')
        if cfg['url'].rstrip('/').split('/')[-1]!=a.instance:raise ValueError('configuration destination differs from --instance')
        print('[PLAN] Publisher '+a.instance+': local aggregate snapshot -> HTTPS hub; persistent outbox; no bot restart.')
        files={}
    slug=local if a.role=='hub' else a.instance
    files[UNITS/f'mediabot-network-publish-{slug}.service']=unit_publisher(slug)
    files[UNITS/f'mediabot-network-publish-{slug}.timer']=unit_timer(slug)
    if not a.apply:
        print('[OK] Setup preview passed. Add --apply to install these files and start only network-stats services.');return
    if os.geteuid()!=0:raise ValueError('installation requires sudo -n python3 setup.py ... --apply')
    # The source package and tests are installed first. Never install unreviewed
    # executable files from the working directory beyond this explicit allowlist.
    backup=Path(tempfile.mkdtemp(prefix='mediabot-network-stats-',dir=BACKUPS));os.chmod(backup,0o700)
    tracked={}
    def remember(path):
        path=Path(path)
        if any(p.is_symlink() for p in (path,*path.parents)):
            raise ValueError('symbolic managed path refused')
        if path.exists():
            st=path.stat();tracked[path]=(path.read_bytes(),st.st_mode&0o777,(st.st_uid,st.st_gid))
            dest=backup/str(path).lstrip('/');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(path,dest)
        else:tracked[path]=None
    owned=[APP/'network_stats.py',APP/'setup.py',*(APP/'static'/n for n in ('index.html','dashboard.js','dashboard.css')),*files]
    publisher_path=ETC/(slug+'.publisher.json');owned.append(publisher_path)
    if a.role=='hub':owned += [ETC/'hub.json',*(BOT_HOME/('network-stats-'+k+'.private.json') for k in streams if k!=local)]
    for path in owned:remember(path)
    hub_unit='mediabot-network-stats.service'
    was_active=subprocess.run(['systemctl','is-active','--quiet',hub_unit]).returncode==0
    timer=f'mediabot-network-publish-{slug}.timer'
    was_timer=subprocess.run(['systemctl','is-active','--quiet',timer]).returncode==0
    was_hub_enabled=subprocess.run(['systemctl','is-enabled','--quiet',hub_unit],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    was_timer_enabled=subprocess.run(['systemctl','is-enabled','--quiet',timer],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
    try:
        for directory in (ETC,APP,APP/'static'):
            managed_directory(directory,0o755,(0,0))
        if a.role=='hub':
            try:pwd.getpwnam('mbnetstats')
            except KeyError:run(['useradd','--system','--home-dir',str(DATA),'--no-create-home','--shell','/usr/sbin/nologin','mbnetstats'])
            hubuser=pwd.getpwnam('mbnetstats');hubowner=(hubuser.pw_uid,hubuser.pw_gid)
            managed_directory(DATA,0o750,hubowner)
            run(['a2enmod','proxy','proxy_http'],True)
            if cfg is None:
                keys={k:secrets.token_urlsafe(36) for k in streams}
                cfg={'bind':'127.0.0.1','port':9409,'database':str(DATA/'history.sqlite3'),'streams':{k:{'label':label,'token_sha256':hashlib.sha256(keys[k].encode()).hexdigest()} for k,label in streams.items()}}
                atomic(ETC/'hub.json',core.encode(cfg),0o640,(0,hubuser.pw_gid))
                for stream in keys:
                    value_for_publisher=keys[stream]
                    pc={'url':('http://127.0.0.1:9409' if stream==local else a.site_url.rstrip('/'))+'/network-stats-api/ingest/'+stream,
                        'token':value_for_publisher,'snapshot':'/home/mediabot/mediabot_v3/var/network-stats.json','state':f'/var/lib/mediabot-network-stats-publisher/{stream}.sqlite3'}
                    dest=publisher_path if stream==local else BOT_HOME/('network-stats-'+stream+'.private.json')
                    atomic(dest,core.encode(pc),0o600,med)
            elif not publisher_path.exists():raise ValueError('existing hub credential cannot be reconstructed; restore the original publisher configuration')
        else:
            atomic(publisher_path,core.encode(cfg),0o600,med)
        managed_directory(PUBLISHER_DATA,0o700,med)
        if a.role=='hub' and was_active:run(['systemctl','stop',hub_unit])
        for src in [HERE/'network_stats.py',HERE/'setup.py',*(HERE/'static'/n for n in ('index.html','dashboard.js','dashboard.css'))]:
            atomic(APP/src.relative_to(HERE),src.read_bytes(),0o644)
        for path,content in files.items():atomic(path,content)
        run(['systemd-analyze','verify',*(str(path) for path in files if path.suffix in ('.service','.timer'))],True)
        if a.role=='hub':run(['apache2ctl','configtest'],True)
        run(['runuser','-u','mediabot','--','/usr/bin/python3','-B',str(APP/'network_stats.py'),'check','--config',str(publisher_path)],True)
        run(['systemctl','daemon-reload'])
        if a.role=='hub':
            run(['systemctl','enable','--now',hub_unit])
            if was_active:run(['systemctl','restart',hub_unit])
            ready=False
            for _ in range(20):
                try:
                    with urlopen('http://127.0.0.1:9409/network-stats-api/health',timeout=1) as response:ready=response.status==200
                except OSError:time.sleep(.25)
                if ready:break
            if not ready:raise ValueError('hub did not become healthy')
            run(['systemctl','reload','apache2'])
            for stream in streams:
                # End-to-end TLS proxy check, not just the internal listener.
                with urlopen(a.site_url.rstrip('/')+'/'+stream+'/data?range=1h',timeout=10) as response:
                    payload=core.strict_json(response.read(1048577))
                    if response.status!=200 or not isinstance(payload,dict) or payload.get('stream')!=stream or 'points' not in payload:raise ValueError('public endpoint health failed')
        run(['systemctl','enable','--now',timer])
        print('[OK] Installed and started. Backup: '+str(backup))
        if a.role=='hub':
            for k in streams:
                if k!=local:print('[NEXT] Private remote configuration: /home/mediabot/network-stats-'+k+'.private.json (transfer over SSH).')
    except Exception:
        subprocess.run(['systemctl','stop',timer],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if not was_timer_enabled:subprocess.run(['systemctl','disable',timer],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if a.role=='hub' and not was_hub_enabled:subprocess.run(['systemctl','disable',hub_unit],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if a.role=='hub':subprocess.run(['systemctl','stop',hub_unit],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        for path,prior in tracked.items():
            if prior is None:path.unlink(missing_ok=True)
            else:atomic(path,prior[0],prior[1],prior[2])
        subprocess.run(['systemctl','daemon-reload'],check=False)
        if a.role=='hub':
            subprocess.run(['apache2ctl','configtest'],check=False)
            subprocess.run(['systemctl','reload','apache2'],check=False)
            if was_active:subprocess.run(['systemctl','start',hub_unit],check=False)
        if was_timer:subprocess.run(['systemctl','start',timer],check=False)
        print('[RECOVERY] Managed files restored; history databases retained. Backup: '+str(backup))
        raise

if __name__=='__main__':
    try:main()
    except Exception as e:
        # Setup input errors can be explained; never echo private configs/keys.
        print(failure_message(e))
        raise SystemExit(1)
