#!/usr/bin/env python3
"""Add one remote stream to the current hub; export a private HTTPS credential.
No publisher or IRC bot is installed/restarted on the web host.
"""
import argparse
import fcntl
import os
from pathlib import Path
import add_local
import setup as deploy


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--instance',required=True)
    p.add_argument('--label',required=True)
    p.add_argument('--publisher-host',required=True)
    p.add_argument('--snapshot',required=True,type=Path)
    p.add_argument('--apache-vhost',required=True,type=Path)
    p.add_argument('--site-url',default='https://teuk.org')
    p.add_argument('--apply',action='store_true')
    a=p.parse_args()
    def plan():
        return add_local.prepare(a.instance,a.label,a.snapshot,a.site_url,a.apache_vhost,a.publisher_host)
    if not a.apply:
        plan()
        print('[OK] Read-only remote stream plan; add --apply to extend the hub.')
        return
    if os.geteuid()!=0:
        raise ValueError('installation requires sudo -n python3 add_remote.py ... --apply')
    fd=os.open(add_local.safe(deploy.ETC/'add-local.lock'),os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        add_local.install(plan())


if __name__=='__main__':
    try:main()
    except Exception as error:
        print(deploy.failure_message(error))
        raise SystemExit(1)
