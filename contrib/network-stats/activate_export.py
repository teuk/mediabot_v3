#!/usr/bin/env python3
"""Audit/activate one systemd-managed bot exporter using the native Conf writer.
Default is read-only. Never guesses a service name or edits a live bot config.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import tempfile
import time
import network_stats as core
import setup as deploy
import add_local as guard


def command(args,cwd=None):
    return subprocess.check_output(args,cwd=cwd,text=True,stderr=subprocess.PIPE).strip()


def configured_network(directory,config):
    # Only print this non-secret label, never the rest of the configuration.
    return command(['perl','-I.','-MMediabot::Conf','-MMediabot::NetworkStats','-e',
        'my $c=Mediabot::Conf->new({},$ARGV[0]); print $c->get("connection.CONN_SERVER_NETWORK") // "";',str(config)],cwd=directory)


def conf_args(args,config):
    encoded=os.fsencode(str(config))
    return b'--conf='+encoded in args or any(a==b'--conf' and args[i+1]==encoded for i,a in enumerate(args[:-1]))


def process(directory,config,uid):
    found=[]
    for path in Path('/proc').glob('[0-9]*'):
        try:
            args=(path/'cmdline').read_bytes().split(b'\0')
            if os.fsencode(str(directory/'mediabot.pl')) not in args or not conf_args(args,config):continue
            if path.stat().st_uid!=uid or (path/'cwd').resolve()!=directory:continue
            found.append(path)
        except (OSError,RuntimeError):continue
    if len(found)!=1:raise ValueError('expected exactly one running bot for this absolute directory/configuration')
    return found[0]


def managed_unit(proc,uid,explicit=None):
    candidates=set(re.findall(r'([^/\n]+\.service)(?:/|$)',(proc/'cgroup').read_text()))
    if explicit:
        if not re.fullmatch(r'[A-Za-z0-9@_.:-]+\.service',explicit):raise ValueError('invalid service unit')
        candidates={explicit}
    found=[]
    for unit in candidates:
        props=command(['systemctl','show',unit,'-p','MainPID','-p','User','-p','ActiveState'])
        state=dict(line.split('=',1) for line in props.splitlines() if '=' in line)
        if state.get('MainPID')==proc.name and state.get('ActiveState')=='active' and state.get('User')==pwd.getpwuid(uid).pw_name:
            found.append(unit)
    if len(found)!=1:raise ValueError('no unique systemd service owns this exact bot PID; no runtime/configuration changed')
    return found[0]


def audit(a):
    if pwd.getpwuid(os.geteuid()).pw_name!='mediabot':raise ValueError('run as mediabot, without sudo')
    # Use the same local host identity as setup.py and the operator's
    # hostname -f precondition. socket.getfqdn() can select a reverse-DNS alias.
    if command(['hostname','-f']).lower()!=a.expected_host.lower():raise ValueError('unexpected bot host')
    directory=guard.safe(a.bot_dir).resolve(strict=True);config=guard.safe(a.bot_conf).resolve(strict=True)
    if not directory.is_absolute() or config.parent!=directory:raise ValueError('expected the explicit configuration in the bot directory')
    if not core.SLUG.fullmatch(a.instance):raise ValueError('invalid instance')
    network=configured_network(directory,config)
    normalize=lambda x: re.sub('[^a-z0-9]','',x.casefold())
    acceptable={normalize(a.network)}
    if normalize(a.network)=='libera':acceptable.add('liberachat')
    if normalize(network) not in acceptable:raise ValueError('actual configured IRC network differs from the requested network')
    proc=process(directory,config,os.getuid());unit=managed_unit(proc,os.getuid(),a.unit)
    publisher=core.load_config(guard.safe(deploy.ETC/(a.instance+'.publisher.json')),'publisher')
    expected_url=a.site_url.rstrip('/')+'/network-stats-api/ingest/'+a.instance
    snapshot=directory/'var/network-stats.json'
    if (publisher['url']!=expected_url or publisher['snapshot']!=str(snapshot)
            or publisher.get('publisher_host')!=a.expected_host
            or publisher['state']!=str(deploy.PUBLISHER_DATA/(a.instance+'.sqlite3'))):
        raise ValueError('private publisher host, route or snapshot binding differs')
    if not guard.active('mediabot-network-publish-'+a.instance+'.timer'):
        raise ValueError('install the matching publisher timer first')
    print('[OK] '+network+' process, directory and configuration verified.')
    print('[PLAN] Exact systemd unit: '+unit+'; snapshot: '+str(snapshot))
    return directory,config,snapshot,unit,proc.name


def activate(a,plan):
    directory,config,snapshot,unit,pid=plan
    # Recheck immediately before stopping, including the configuration's inode
    # contents: a config saved by the bot before stop is backed up after stop.
    if process(directory,config,os.getuid()).name!=pid or managed_unit(Path('/proc')/pid,os.getuid(),unit)!=unit:
        raise ValueError('bot process changed since audit')
    subprocess.run(['sudo','-n','systemctl','stop',unit],check=True)
    backup=None
    try:
        backup=Path(tempfile.mkdtemp(prefix='network-export-conf-',dir=directory.parent));os.chmod(backup,0o700)
        shutil.copy2(config,backup/config.name)
        print('[BACKUP] '+str(backup))
        perl=r'''
use Mediabot::Conf;use JSON::PP;
my ($file,$output)=@ARGV;my $c=Mediabot::Conf->new({},$file);my %before=$c->all;
$c->set('network_stats.ENABLED',1);$c->set('network_stats.OUTPUT_FILE',$output);$c->set('main.LUSERS_REFRESH',300);$c->save;
my $r=Mediabot::Conf->new({},$file);my %after=$r->all;
die "Exporter settings did not reread\n" unless ($r->get('network_stats.ENABLED')//'') eq '1'
 && ($r->get('network_stats.OUTPUT_FILE')//'') eq $output && ($r->get('main.LUSERS_REFRESH')//'') eq '300';
for my $k(qw(network_stats.ENABLED network_stats.OUTPUT_FILE main.LUSERS_REFRESH)){delete $before{$k};delete $after{$k};}
my $j=JSON::PP->new->canonical;die "Other configuration fields changed\n" unless $j->encode(\%before) eq $j->encode(\%after);
'''
        subprocess.run(['perl','-I.','-e',perl,str(config),str(snapshot)],cwd=directory,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        subprocess.run(['sudo','-n','systemctl','start',unit],check=True)
        for i in range(20):
            try:
                new=process(directory,config,os.getuid());managed_unit(new,os.getuid(),unit);break
            except ValueError:
                if i==19:raise
                time.sleep(.25)
    except Exception:
        # Never overwrite a config still held by the replacement process.
        stopped=subprocess.run(['sudo','-n','systemctl','stop',unit],check=False).returncode==0
        restored=False
        if stopped and backup and (backup/config.name).exists():
            try:shutil.copy2(backup/config.name,config);restored=True
            except OSError:pass
        started=subprocess.run(['sudo','-n','systemctl','start',unit],check=False).returncode==0
        print('[RECOVERY] '+('Previous configuration restored and start requested.' if restored and started else 'Local inspection required; private backup: '+str(backup)))
        raise
    print('[OK] Export enabled with the native writer; only the verified bot unit restarted.')
    print('[NEXT] Check a fresh LUSERS observation and '+a.site_url.rstrip('/')+'/'+a.instance)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--instance',required=True);p.add_argument('--network',required=True)
    p.add_argument('--expected-host',required=True)
    p.add_argument('--bot-dir',required=True,type=Path);p.add_argument('--bot-conf',required=True,type=Path)
    p.add_argument('--site-url',default='https://teuk.org');p.add_argument('--unit')
    p.add_argument('--apply',action='store_true');a=p.parse_args()
    deploy.profile(a.site_url,[a.instance+'='+a.network],a.instance)
    plan=audit(a)
    if a.apply:activate(a,plan)
    else:print('[OK] Read-only activation audit; add --apply to activate this exact bot.')


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(deploy.failure_message(error));raise SystemExit(1)
