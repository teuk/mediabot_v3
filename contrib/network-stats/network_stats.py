#!/usr/bin/env python3
"""Mediabot aggregate network history, HTTP dashboard and durable publisher.
Python standard library only; no IRC/SQL account or shell commands at request time.
"""
from __future__ import annotations
from contextlib import contextmanager, closing
import argparse
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from urllib.request import Request, build_opener, HTTPSHandler, HTTPRedirectHandler, ProxyHandler

FIELDS = ('users', 'visible_users', 'invisible_users', 'channels', 'operators', 'servers',
          'unknown_connections', 'local_users', 'local_users_max', 'local_servers', 'global_users', 'users_max')
RANGES = {'1h':3600, '6h':21600, '24h':86400, '7d':604800, '30d':2592000, '90d':7776000}
SLUG = re.compile(r'[a-z][a-z0-9-]{0,39}\Z')
MAX_BODY = 192 * 1024
RETENTION = 90 * 86400
STATIC = Path(__file__).resolve().parent / 'static'


def encode(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')


def strict_json(raw):
    def pairs(items):
        result = {}
        for key, val in items:
            if key in result:
                raise ValueError('duplicate key')
            result[key] = val
        return result
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite')))


def integer(v, lo, hi):
    if type(v) is not int or not lo <= v <= hi:
        raise ValueError('invalid integer')
    return v


def sample(value, now=None):
    now = int(time.time()) if now is None else now
    if not isinstance(value, dict) or set(value) != {'schema','sampled_at','network','interval','counts'}:
        raise ValueError('invalid sample fields')
    if type(value['schema']) is not int or value['schema'] != 1:
        raise ValueError('invalid schema')
    integer(value['sampled_at'], now-RETENTION, now+60)
    integer(value['interval'], 60, 3600)
    name = value['network']
    if not isinstance(name, str) or not 1 <= len(name) <= 80 or any(ord(c)<32 or ord(c)==127 for c in name):
        raise ValueError('invalid network name')
    counts = value['counts']
    if not isinstance(counts, dict) or not counts or set(counts) - set(FIELDS):
        raise ValueError('invalid counts')
    for v in counts.values():
        integer(v, 0, 2147483647)
    if 'users' not in counts:
        raise ValueError('missing user count')
    if all(k in counts for k in ('users', 'visible_users', 'invisible_users')) and counts['users'] != counts['visible_users'] + counts['invisible_users']:
        raise ValueError('inconsistent split')
    return value


def load_config(path, role):
    p = Path(path)
    if p.is_symlink() or not p.is_file() or p.stat().st_size > 65536:
        raise ValueError('invalid configuration file')
    cfg = strict_json(p.read_bytes())
    if not isinstance(cfg,dict):raise ValueError('configuration must be an object')
    if role == 'hub':
        if cfg.get('bind', '127.0.0.1') not in ('127.0.0.1', '::1'):
            raise ValueError('hub must bind loopback behind HTTPS proxy')
        integer(cfg.get('port',9409),1024,65535)
        streams = cfg.get('streams')
        if not isinstance(streams, dict) or not 1 <= len(streams) <= 16:
            raise ValueError('invalid streams')
        for slug, meta in streams.items():
            if not SLUG.fullmatch(slug) or not isinstance(meta, dict):
                raise ValueError('invalid stream')
            if not re.fullmatch('[a-f0-9]{64}',meta.get('token_sha256','')):
                raise ValueError('invalid stream credential hash')
            if not isinstance(meta.get('label'),str) or not 1 <= len(meta['label']) <= 80:
                raise ValueError('invalid label')
    else:
        u = urlsplit(cfg.get('url',''))
        if u.username or u.password or u.query or u.fragment or not u.hostname:
            raise ValueError('invalid publisher URL')
        if not re.fullmatch('/network-stats-api/ingest/[a-z][a-z0-9-]{0,39}',u.path):
            raise ValueError('invalid ingest path')
        if u.scheme != 'https' and not (u.scheme=='http' and u.hostname in ('127.0.0.1','::1')):
            raise ValueError('HTTPS required for remote publishing')
        if not re.fullmatch('[A-Za-z0-9_-]{40,128}',cfg.get('token','')):
            raise ValueError('invalid publisher credential')
        for key in ('snapshot','state'):
            if not Path(cfg.get(key,'')).is_absolute():
                raise ValueError('absolute paths required')
    if not Path(cfg.get('database' if role=='hub' else 'state','')).is_absolute():
        raise ValueError('absolute database path required')
    return cfg


class History:
    def __init__(self, path):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True, mode=0o750)
        with self.connect() as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute('CREATE TABLE IF NOT EXISTS samples (stream TEXT NOT NULL, ts INTEGER NOT NULL, network TEXT NOT NULL, cadence INTEGER NOT NULL, counts TEXT NOT NULL, PRIMARY KEY(stream,ts))')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def ingest(self, stream, samples, now=None):
        now = int(time.time()) if now is None else now
        if not isinstance(samples,list) or not 1 <= len(samples) <= 256:
            raise ValueError('invalid sample batch')
        validated = [sample(x,now) for x in samples]
        with self.connect() as db:
            db.executemany('INSERT INTO samples VALUES (?,?,?,?,?) ON CONFLICT(stream,ts) DO UPDATE SET network=excluded.network,cadence=excluded.cadence,counts=excluded.counts',
                           [(stream,x['sampled_at'],x['network'],x['interval'],encode(x['counts']).decode()) for x in validated])
            db.execute('DELETE FROM samples WHERE ts < ?', (now-RETENTION,))
            # Also bound disk growth if a credential holder sends too often.
            db.execute('DELETE FROM samples WHERE stream=? AND ts < COALESCE((SELECT ts FROM samples WHERE stream=? ORDER BY ts DESC LIMIT 1 OFFSET 49999),0)',(stream,stream))
        return [x['sampled_at'] for x in validated]

    @staticmethod
    def unpack(row):
        if row is None:
            return None
        return {'ts':row['ts'],'network':row['network'],'interval':row['cadence'],'counts':strict_json(row['counts'])}

    def query(self, stream, span, now=None):
        now = int(time.time()) if now is None else now
        since = now-RANGES[span]
        bucket = max(1,math.ceil(RANGES[span]/600))
        with self.connect() as db:
            db.execute('DELETE FROM samples WHERE ts < ?', (now-RETENTION,))
            latest=self.unpack(db.execute('SELECT * FROM samples WHERE stream=? ORDER BY ts DESC LIMIT 1',(stream,)).fetchone())
            # Return real last observations, not invented average headcounts.
            rows=db.execute('SELECT s.* FROM samples s JOIN (SELECT MAX(ts) ts FROM samples WHERE stream=? AND ts>=? AND ts<=? GROUP BY CAST((ts-?)/? AS INTEGER)) b ON s.ts=b.ts WHERE s.stream=? ORDER BY s.ts',
                            (stream,since,now,since,bucket,stream)).fetchall()
            raw=db.execute('SELECT counts FROM samples WHERE stream=? AND ts>=? AND ts<=?',(stream,since,now)).fetchall()
        summary={}
        for row in raw:
            for key,val in strict_json(row['counts']).items():
                stat=summary.setdefault(key,{'min':val,'max':val,'sum':0,'n':0})
                stat['min']=min(stat['min'],val);stat['max']=max(stat['max'],val);stat['sum']+=val;stat['n']+=1
        for val in summary.values():
            val['mean']=round(val.pop('sum')/val['n'],2)
        return {'now':now,'from':since,'range':span,'bucket_seconds':bucket,'latest':latest,
                'points':[self.unpack(row) for row in rows],'samples':len(raw),'summary':summary}


class Server(ThreadingHTTPServer):
    daemon_threads=True
    allow_reuse_address=True
    def __init__(self,addr,cfg):
        self.address_family=socket.AF_INET6 if ':' in addr[0] else socket.AF_INET
        self.cfg=cfg;self.history=History(cfg['database']);self.slots=threading.BoundedSemaphore(12)
        super().__init__(addr, Handler)
    def process_request(self,request,address):
        if not self.slots.acquire(blocking=False):
            request.close();return
        super().process_request(request,address)
    def process_request_thread(self,request,address):
        try:
            request.settimeout(10)
            super().process_request_thread(request,address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version='MediabotNetworkStats/1'
    def log_message(self,*args):
        pass  # Never log Authorization, request bodies or query strings.
    def send(self,status,body,kind='application/json; charset=utf-8'):
        self.send_response(status)
        self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(body)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
    def error(self,status,code):
        self.send(status,encode({'error':code}))
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        try:
            u=urlsplit(self.path)
            if u.path=='/network-stats-api/health':
                with self.server.history.connect() as db: db.execute('SELECT count(*) FROM samples').fetchone()
                return self.send(200,encode({'ok':True}))
            for slug,meta in self.server.cfg['streams'].items():
                if u.path in ('/'+slug,'/'+slug+'/'):
                    return self.send(200,(STATIC/'index.html').read_bytes(),'text/html; charset=utf-8')
                if u.path=='/'+slug+'/data':
                    q=parse_qs(u.query,keep_blank_values=True,strict_parsing=True) if u.query else {}
                    if set(q)-{'range'} or len(q.get('range',[]))>1 or q.get('range',['24h'])[0] not in RANGES:
                        return self.error(400,'invalid_range')
                    data=self.server.history.query(slug,q.get('range',['24h'])[0])
                    data.update(label=meta['label'],stream=slug,retention_days=90,streams=[{'id':k,'label':v['label']} for k,v in self.server.cfg['streams'].items()])
                    return self.send(200,encode(data))
            if u.path.startswith('/network-stats-assets/'):
                name=u.path.removeprefix('/network-stats-assets/')
                kinds={'dashboard.js':'text/javascript; charset=utf-8','dashboard.css':'text/css; charset=utf-8'}
                if name in kinds:
                    return self.send(200,(STATIC/name).read_bytes(),kinds[name])
            self.error(404,'not_found')
        except (ValueError,UnicodeError):
            self.error(400,'invalid_request')
        except (OSError,sqlite3.Error):
            self.error(503,'temporarily_unavailable')
    def do_POST(self):
        try:
            u=urlsplit(self.path)
            prefix='/network-stats-api/ingest/'
            slug=u.path.removeprefix(prefix) if u.path.startswith(prefix) else ''
            meta=self.server.cfg['streams'].get(slug)
            auth=self.headers.get_all('Authorization',[])
            if not meta or len(auth)!=1 or u.query or u.fragment:
                return self.error(403,'forbidden')
            given=hashlib.sha256(auth[0].removeprefix('Bearer ').encode()).hexdigest()
            if not auth[0].startswith('Bearer ') or not hmac.compare_digest(given,meta['token_sha256']):
                return self.error(403,'forbidden')
            sizes=self.headers.get_all('Content-Length',[])
            if self.headers.get('Transfer-Encoding') or len(sizes)!=1 or not re.fullmatch('[0-9]{1,6}',sizes[0]):
                return self.error(400,'invalid_length')
            length=int(sizes[0])
            if not 1<=length<=MAX_BODY:
                return self.error(413,'too_large')
            if self.headers.get_content_type()!='application/json':
                return self.error(415,'json_required')
            body=self.rfile.read(length)
            if len(body)!=length:
                return self.error(400,'incomplete_body')
            data=strict_json(body)
            if not isinstance(data,dict) or set(data)!={'samples'}:
                return self.error(400,'invalid_batch')
            accepted=self.server.history.ingest(slug,data['samples'])
            self.send(200,encode({'accepted':accepted}))
        except (ValueError,UnicodeError,TypeError,KeyError):
            self.error(400,'invalid_sample')
        except (OSError,sqlite3.Error):
            self.error(503,'temporarily_unavailable')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        raise ValueError('publisher redirects are refused')


def publish(cfg, opener=None, now=None):
    now=int(time.time()) if now is None else now
    state=Path(cfg['state']);state.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with closing(sqlite3.connect(state,timeout=5)) as db:
        db.execute('CREATE TABLE IF NOT EXISTS queue (ts INTEGER PRIMARY KEY, payload BLOB NOT NULL)')
        db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)')
        prior=db.execute("SELECT value FROM meta WHERE key='destination'").fetchone()
        if prior and prior[0]!=cfg['url']:
            raise ValueError('outbox belongs to another destination')
        db.execute('INSERT OR IGNORE INTO meta VALUES (?,?)',('destination',cfg['url']))
        p=Path(cfg['snapshot'])
        if p.is_symlink():
            raise ValueError('symbolic snapshot refused')
        if p.exists():
            if not p.is_file() or p.stat().st_size>16384:
                raise ValueError('invalid snapshot size')
            data=sample(strict_json(p.read_bytes()),now)
            blob=encode(data);fingerprint=hashlib.sha256(blob).hexdigest()
            old=db.execute("SELECT value FROM meta WHERE key='last_snapshot'").fetchone()
            if not old or old[0]!=fingerprint:
                db.execute('INSERT INTO queue VALUES (?,?) ON CONFLICT(ts) DO UPDATE SET payload=excluded.payload',(data['sampled_at'],blob))
                db.execute('INSERT OR REPLACE INTO meta VALUES (?,?)',('last_snapshot',fingerprint))
        db.execute('DELETE FROM queue WHERE ts<?',(now-30*86400,))
        db.execute('DELETE FROM queue WHERE ts < COALESCE((SELECT ts FROM queue ORDER BY ts DESC LIMIT 1 OFFSET 9999),0)')
        db.commit()  # Durable before making any network request.
        rows=db.execute('SELECT ts,payload FROM queue ORDER BY ts LIMIT 256').fetchall()
        if not rows:
            return 0
        payload=encode({'samples':[strict_json(row[1]) for row in rows]})
        if len(payload)>MAX_BODY:
            raise ValueError('batch too large')
        if opener is None:
            opener=build_opener(ProxyHandler({}),NoRedirect(),HTTPSHandler(context=ssl.create_default_context()))
        request=Request(cfg['url'],data=payload,headers={'Content-Type':'application/json','Authorization':'Bearer '+cfg['token']},method='POST')
        with opener.open(request,timeout=15) as response:
            raw=response.read(16385)
            if response.status!=200 or len(raw)>16384:
                raise ValueError('invalid acknowledgement')
            ack=strict_json(raw)
            if not isinstance(ack,dict) or ack.get('accepted')!=[row[0] for row in rows]:
                raise ValueError('acknowledgement differs from batch')
        db.executemany('DELETE FROM queue WHERE ts=?',[(row[0],) for row in rows])
        db.commit()
        return len(rows)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command',choices=('serve','publish','check'))
    p.add_argument('--config',required=True)
    p.add_argument('--role',choices=('hub','publisher'),default='publisher')
    a=p.parse_args();os.umask(0o077)
    role='hub' if a.command=='serve' else a.role
    cfg=load_config(a.config,role)
    if a.command=='check':
        print('[OK] Network stats configuration valid; credentials hidden.');return
    if a.command=='serve':
        server=Server((cfg.get('bind','127.0.0.1'),cfg.get('port',9409)),cfg)
        print('[OK] Aggregate network history ready on loopback.',flush=True)
        server.serve_forever()
    else:
        count=publish(cfg)
        print(f'[OK] Network stats publisher acknowledged {count} sample(s).',flush=True)

if __name__=='__main__':
    try:
        main()
    except (OSError,ValueError,sqlite3.Error) as exc:
        print('[KO] Network stats operation failed ('+type(exc).__name__+'); queued samples retained, credentials hidden.',flush=True)
        raise SystemExit(1)
