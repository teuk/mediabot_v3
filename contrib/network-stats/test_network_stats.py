import copy
import hashlib
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch
from urllib.request import build_opener, ProxyHandler
from urllib.error import URLError

import network_stats as n
import setup


def generate_tls_fixture(root):
    """Generate a local test certificate independently of runner OpenSSL config."""
    cert=root/'cert.pem';key=root/'key.pem';config=root/'openssl-test.cnf'
    config.write_text('''[req]
prompt=no
distinguished_name=dn
x509_extensions=server_ext
[dn]
CN=localhost
[server_ext]
subjectAltName=DNS:localhost
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage=serverAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
''',encoding='ascii')
    # Set both startup and req configuration for this subprocess only. CI Perl
    # toolchains may advertise an OpenSSL config outside the system installation.
    environment=dict(os.environ,OPENSSL_CONF=str(config))
    try:
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes',
            '-sha256','-config',str(config),'-keyout',str(key),'-out',str(cert),
            '-days','1'],check=True,capture_output=True,text=True,
            timeout=15,env=environment)
    except subprocess.CalledProcessError as exc:
        detail=(exc.stderr or '').strip()[-2000:]
        raise RuntimeError(f'OpenSSL test certificate generation failed (exit {exc.returncode}): {detail}') from None
    except subprocess.TimeoutExpired:
        raise RuntimeError('OpenSSL test certificate generation exceeded 15 seconds') from None
    return cert,key


class StatsTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name);self.now=int(time.time())
        self.token='x'*48
        self.cfg={'database':str(self.root/'hub.sqlite3'),'streams':{
            'mbdev':{'label':'Dev','token_sha256':hashlib.sha256(self.token.encode()).hexdigest()},
            'epiknet':{'label':'EpikNet','token_sha256':hashlib.sha256(('f'*48).encode()).hexdigest()}}}
        self.s={'schema':1,'sampled_at':self.now-10,'network':'Test','interval':300,
                'counts':{'users':100,'visible_users':30,'invisible_users':70,'channels':22,'operators':0}}
    def tearDown(self):self.tmp.cleanup()
    def server(self):
        # Only shorten the fixture's idle shutdown poll, not request/TLS timeouts.
        srv=n.Server(('127.0.0.1',0),self.cfg);thread=threading.Thread(target=srv.serve_forever,kwargs={'poll_interval':0.01},daemon=True);thread.start()
        self.addCleanup(srv.server_close);self.addCleanup(srv.shutdown)
        return srv
    def request(self,srv,path,body=None,token=None,headers=None):
        conn=http.client.HTTPConnection('127.0.0.1',srv.server_port,timeout=2)
        h={'Content-Type':'application/json'}
        if token:h['Authorization']='Bearer '+token
        if headers:h.update(headers)
        conn.request('POST' if body is not None else 'GET',path,body=body,headers=h)
        response=conn.getresponse();result=(response.status,dict(response.headers),response.read());conn.close();return result
    def publisher_cfg(self,srv):
        value_for_publisher=self.token
        return {'url':f'http://127.0.0.1:{srv.server_port}/network-stats-api/ingest/mbdev',
                'token':value_for_publisher,'snapshot':str(self.root/'snapshot.json'),'state':str(self.root/'outbox.sqlite3')}
    def test_roundtrip_two_instances_and_no_secret_in_public(self):
        srv=self.server()
        for slug,token in [('mbdev',self.token),('epiknet','f'*48)]:
            status,_,body=self.request(srv,'/network-stats-api/ingest/'+slug,n.encode({'samples':[self.s]}),token)
            self.assertEqual(status,200);self.assertEqual(json.loads(body)['accepted'],[self.s['sampled_at']])
        for slug in ['mbdev','epiknet']:
            status,headers,body=self.request(srv,'/'+slug+'/data?range=24h')
            self.assertEqual(status,200);self.assertEqual(json.loads(body)['latest']['counts']['operators'],0)
            self.assertNotIn(self.token,body.decode());self.assertNotIn('token_sha256',body.decode())
            self.assertIn("default-src 'none'",headers['Content-Security-Policy'])
    def test_cross_instance_credential_rejected(self):
        srv=self.server();status,_,_=self.request(srv,'/network-stats-api/ingest/epiknet',n.encode({'samples':[self.s]}),self.token)
        self.assertEqual(status,403)
        self.assertIsNone(srv.history.query('epiknet','1h')['latest'])
    def test_invalid_payload_limits_and_schema_over_http(self):
        srv=self.server();path='/network-stats-api/ingest/mbdev'
        for body,status in [(b'{"samples":[],"samples":[]}',400),(b'{"samples":[]}',400),(b'x'*(n.MAX_BODY+1),413),(b'{"other":1}',400)]:
            self.assertEqual(self.request(srv,path,body,self.token)[0],status)
        self.assertEqual(self.request(srv,path,n.encode({'samples':[self.s]}),self.token,{'Content-Type':'text/plain'})[0],415)
        self.assertEqual(srv.history.query('mbdev','1h')['samples'],0)

    def test_real_tls_verification_and_queued_retry(self):
        self.assert_real_tls_verification_and_queued_retry()

    def test_real_tls_with_missing_ambient_openssl_configuration(self):
        missing=str(self.root/'missing-system-openssl.cnf')
        with patch.dict(os.environ,{'OPENSSL_CONF':missing}):
            self.assert_real_tls_verification_and_queued_retry()
            self.assertEqual(os.environ['OPENSSL_CONF'],missing)

    def test_real_tls_with_malformed_ambient_openssl_configuration(self):
        invalid=self.root/'invalid-system-openssl.cnf'
        invalid.write_text('this is not a valid openssl configuration\n',encoding='ascii')
        with patch.dict(os.environ,{'OPENSSL_CONF':str(invalid)}):
            self.assert_real_tls_verification_and_queued_retry()
            self.assertEqual(os.environ['OPENSSL_CONF'],str(invalid))

    def assert_real_tls_verification_and_queued_retry(self):
        cert,key=generate_tls_fixture(self.root)
        srv=n.Server(('127.0.0.1',0),self.cfg)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
        srv.socket=context.wrap_socket(srv.socket,server_side=True)
        thread=threading.Thread(target=srv.serve_forever,kwargs={'poll_interval':0.01},daemon=True);thread.start()
        self.addCleanup(srv.server_close);self.addCleanup(srv.shutdown)
        cfg=self.publisher_cfg(srv);cfg['url']=cfg['url'].replace('http://127.0.0.1','https://localhost')
        Path(cfg['snapshot']).write_bytes(n.encode(self.s))
        with self.assertRaises(URLError) as rejected:n.publish(cfg)
        self.assertIsInstance(rejected.exception.reason,ssl.SSLCertVerificationError)
        with sqlite3.connect(cfg['state']) as db:self.assertEqual(db.execute('SELECT count(*) FROM queue').fetchone()[0],1)
        self.assertEqual(srv.history.query('mbdev','1h')['samples'],0)
        trusted=build_opener(ProxyHandler({}),n.NoRedirect(),n.HTTPSHandler(context=ssl.create_default_context(cafile=str(cert))))
        self.assertEqual(n.publish(cfg,opener=trusted),1)
        self.assertEqual(srv.history.query('mbdev','1h')['samples'],1)
        with sqlite3.connect(cfg['state']) as db:self.assertEqual(db.execute('SELECT count(*) FROM queue').fetchone()[0],0)

    def test_unknown_path_traversal_and_ranges(self):
        srv=self.server()
        for path in ['/unknown','/mbdevil','/network-stats-assets/../network_stats.py','/network-stats-assets/%2e%2e/network_stats.py']:
            self.assertEqual(self.request(srv,path)[0],404)
        for q in ['range=forever','range=1h&range=7d','range=','x=y','bad']:
            self.assertEqual(self.request(srv,'/mbdev/data?'+q)[0],400)
    def test_invalid_batch_atomic(self):
        h=n.History(self.root/'test.sqlite3');bad=copy.deepcopy(self.s);bad['counts']['users']='100'
        with self.assertRaises(ValueError):h.ingest('mbdev',[self.s,bad],self.now)
        self.assertEqual(h.query('mbdev','1h',self.now)['samples'],0)
    def test_count_schema_and_limits(self):
        for value in [-1,True,1.5,2147483648,'4',None]:
            s=copy.deepcopy(self.s);s['counts']['channels']=value
            with self.subTest(value=value),self.assertRaises(ValueError):n.sample(s,self.now)
        for key,val in [('sampled_at',self.now+61),('interval',0),('network','bad\nname'),('schema',True)]:
            s=copy.deepcopy(self.s);s[key]=val
            with self.assertRaises(ValueError):n.sample(s,self.now)
        s=copy.deepcopy(self.s);s['counts']['password']=3
        with self.assertRaises(ValueError):n.sample(s,self.now)
        s=copy.deepcopy(self.s);s['counts']['users']=1
        with self.assertRaises(ValueError):n.sample(s,self.now)
    def test_duplicate_json_key_and_nonfinite(self):
        for raw in [b'{"x":1,"x":2}',b'{"x":NaN}']:
            with self.assertRaises(ValueError):n.strict_json(raw)
    def test_unknown_values_are_not_zero(self):
        s=copy.deepcopy(self.s);del s['counts']['operators'];h=n.History(self.root/'x.db');h.ingest('x',[s],self.now)
        q=h.query('x','1h',self.now);self.assertNotIn('operators',q['latest']['counts']);self.assertNotIn('operators',q['summary'])
    def test_replay_idempotence_and_history_restart(self):
        p=self.root/'x.db';h=n.History(p);h.ingest('x',[self.s],self.now);h.ingest('x',[self.s],self.now)
        self.assertEqual(n.History(p).query('x','1h',self.now)['samples'],1)
    def test_downsampling_preserves_observed_values_and_exact_extrema(self):
        h=n.History(self.root/'x.db');samples=[]
        for i in range(2000):
            s=copy.deepcopy(self.s);s['sampled_at']=self.now-8000+i*4;s['counts']={'users':i};samples.append(s)
        for start in range(0,len(samples),250):h.ingest('x',samples[start:start+250],self.now)
        q=h.query('x','24h',self.now)
        self.assertLessEqual(len(q['points']),601);self.assertEqual(q['samples'],2000)
        self.assertEqual(q['summary']['users']['min'],0);self.assertEqual(q['summary']['users']['max'],1999)
        for p in q['points']:self.assertEqual(p['counts']['users'],(p['ts']-(self.now-8000))//4)
    def test_range_does_not_reset_latest_or_make_stale_fresh(self):
        h=n.History(self.root/'x.db');s=copy.deepcopy(self.s);s['sampled_at']=self.now-7200;h.ingest('x',[s],self.now)
        q=h.query('x','1h',self.now);self.assertEqual(q['points'],[]);self.assertEqual(q['latest']['ts'],self.now-7200)
    def test_actual_perl_export_to_remote_history(self):
        root=Path(__file__).resolve().parents[2]
        path=self.root/'from-bot.json'
        script=r'''use Mediabot::NetworkStats;
            {package C;sub get {$_[0]->{$_[1]}}}
            my $now=time();
            my $conf=bless {'network_stats.ENABLED'=>1,'network_stats.OUTPUT_FILE'=>$ARGV[0],
                'connection.CONN_SERVER_NETWORK'=>'Integration network'},'C';
            my $r=Mediabot::NetworkStats->new(conf=>$conf,now=>sub{$now});
            $r->observe('251',['17','83','4'],'');
            $r->observe('252',['0'],'');$r->observe('254',['22'],'');
            $r->observe('255',[],'I have 45 clients and 3 servers');
            $r->observe('266',['100','200'],'');
            $now+=3;die 'export failed' unless $r->flush;
        '''
        subprocess.run(['perl','-I.','-e',script,str(path)],cwd=root,check=True,capture_output=True)
        srv=self.server();cfg=self.publisher_cfg(srv);cfg['snapshot']=str(path)
        self.assertEqual(n.publish(cfg),1)
        latest=srv.history.query('mbdev','1h')['latest']
        self.assertEqual(latest['counts']['visible_users'],17)
        self.assertEqual(latest['counts']['operators'],0)
        self.assertEqual(latest['network'],'Integration network')

    def test_publisher_roundtrip_and_deduplication(self):
        srv=self.server();cfg=self.publisher_cfg(srv);Path(cfg['snapshot']).write_bytes(n.encode(self.s))
        self.assertEqual(n.publish(cfg),1);self.assertEqual(n.publish(cfg),0)
        with sqlite3.connect(cfg['state']) as db:self.assertEqual(db.execute('SELECT count(*) FROM queue').fetchone()[0],0)
    def test_publisher_durable_outbox_recovery_with_next_sample(self):
        srv=self.server();cfg=self.publisher_cfg(srv);p=Path(cfg['snapshot']);p.write_bytes(n.encode(self.s))
        class Fail:
            def open(self,*a,**kw):raise OSError('offline')
        with self.assertRaises(OSError):n.publish(cfg,opener=Fail())
        with sqlite3.connect(cfg['state']) as db:self.assertEqual(db.execute('SELECT count(*) FROM queue').fetchone()[0],1)
        newer=copy.deepcopy(self.s);newer['sampled_at']+=5;p.write_bytes(n.encode(newer))
        self.assertEqual(n.publish(cfg),2);self.assertEqual(srv.history.query('mbdev','1h')['samples'],2)
    def test_wrong_ack_retains_queue(self):
        srv=self.server();cfg=self.publisher_cfg(srv);Path(cfg['snapshot']).write_bytes(n.encode(self.s))
        class Response(io.BytesIO):status=200
        class Wrong:
            def open(self,*a,**kw):return Response(b'{"accepted":[]}')
        with self.assertRaises(ValueError):n.publish(cfg,opener=Wrong())
        self.assertEqual(n.publish(cfg),1)
    def test_outbox_cannot_switch_destination(self):
        srv=self.server();cfg=self.publisher_cfg(srv);n.publish(cfg);cfg['url']+='-other'
        with self.assertRaises(ValueError):n.publish(cfg)
    def test_snapshot_symlink_and_empty_start(self):
        srv=self.server();cfg=self.publisher_cfg(srv);self.assertEqual(n.publish(cfg),0)
        p=Path(cfg['snapshot']);p.symlink_to(self.root/'victim')
        with self.assertRaises(ValueError):n.publish(cfg)
    def test_remote_transport_requires_tls_and_no_redirect(self):
        value_for_publisher=self.token
        c={'url':'http://example.com/network-stats-api/ingest/mbdev','token':value_for_publisher,'snapshot':str(self.root/'s'),'state':str(self.root/'o')};p=self.root/'c.json';p.write_bytes(n.encode(c))
        with self.assertRaises(ValueError):n.load_config(p,'publisher')
        c['url']='https://example.com/network-stats-api/ingest/mbdev';p.write_bytes(n.encode(c));self.assertEqual(n.load_config(p,'publisher')['url'],c['url'])
        with self.assertRaises(ValueError):n.NoRedirect().redirect_request(None,None,None,None,None,None)
    def test_html_assets_and_no_inline_dynamic_html(self):
        srv=self.server()
        for path,kind in [('/mbdev','text/html'),('/epiknet/','text/html'),('/network-stats-assets/dashboard.js','text/javascript'),('/network-stats-assets/dashboard.css','text/css')]:
            st,h,b=self.request(srv,path);self.assertEqual(st,200);self.assertTrue(h['Content-Type'].startswith(kind));self.assertGreater(len(b),1000)
        script=(n.STATIC/'dashboard.js').read_text();self.assertNotIn('innerHTML',script);self.assertNotIn('eval(',script)
    def test_setup_vhost_insertion_is_scoped_idempotent(self):
        s='<VirtualHost *:443>\nServerName teuk.org\n</VirtualHost>\n';updated=setup.vhost_include(s)
        self.assertEqual(updated.count('Include /etc/apache2/mediabot-network-stats.conf'),1);self.assertEqual(setup.vhost_include(updated),updated)
        for bad in [s+s,s.replace(':443',':80'),s.replace('teuk.org','other.org')]:
            with self.assertRaises(ValueError):setup.vhost_include(bad)
    def exercise_setup(self, fail=False, repeat=False, role='hub'):
        etc=self.root/'etc';apache=etc/'apache2';apache.mkdir(parents=True)
        vhost=apache/'site.conf';original='<VirtualHost *:443>\nServerName teuk.org\n</VirtualHost>\n';vhost.write_text(original)
        home=self.root/'home';home.mkdir();backups=self.root/'backups';backups.mkdir()
        constants={'APP':self.root/'app','ETC':etc/'stats','DATA':self.root/'history','INCLUDE':apache/'stats.conf',
                   'APACHE_ROOT':apache,'UNITS':etc/'systemd','BOT_HOME':home,'BACKUPS':backups,'PUBLISHER_DATA':self.root/'outbox'}
        calls=[]
        def command(args,capture=False):
            calls.append(args)
            return 'teuk.org' if args[0]=='hostname' else ''
        class Response(io.BytesIO):status=200
        def response(url,timeout):
            if url.startswith('https:'):
                if fail:raise OSError('simulated TLS failure')
                slug=url.split('/')[3]
                return Response(n.encode({'stream':slug,'points':[]}))
            return Response(b'{"ok":true}')
        identity=types.SimpleNamespace(pw_uid=0,pw_gid=0)
        arguments=['setup.py','hub','--apache-vhost',str(vhost),'--apply']
        if role=='publisher':
            pc=self.publisher_cfg(types.SimpleNamespace(server_port=9409))
            pc['url']='https://example.com/network-stats-api/ingest/epiknet'
            pc['state']=str(constants['PUBLISHER_DATA']/'epiknet.sqlite3')
            source=home/'publisher.json';source.write_bytes(n.encode(pc));source.chmod(0o600)
            arguments=['setup.py','publisher','--instance','epiknet','--publisher-config',str(source),'--apply']
        from contextlib import ExitStack, redirect_stdout
        with ExitStack() as stack:
            stack.enter_context(redirect_stdout(io.StringIO()))
            for key,val in constants.items():stack.enter_context(patch.object(setup,key,val))
            stack.enter_context(patch.object(setup,'run',command))
            stack.enter_context(patch.object(setup,'urlopen',response))
            stack.enter_context(patch.object(setup.pwd,'getpwnam',return_value=identity))
            stack.enter_context(patch.object(setup.os,'geteuid',return_value=0))
            stack.enter_context(patch.object(setup.os,'chown'))
            stack.enter_context(patch.object(setup.subprocess,'run',return_value=types.SimpleNamespace(returncode=1)))
            stack.enter_context(patch.object(sys,'argv',arguments))
            if fail:
                with self.assertRaises(OSError):setup.main()
            else:
                setup.main()
                if repeat:
                    credentials=constants['ETC']/('hub.json' if role=='hub' else 'epiknet.publisher.json')
                    original_keys=credentials.read_bytes()
                    setup.main()
                    self.assertEqual(credentials.read_bytes(),original_keys)
        return constants,calls,vhost,original

    def test_setup_apply_installs_scoped_files_and_separate_credentials(self):
        paths,calls,vhost,original=self.exercise_setup(repeat=True)
        hub=n.load_config(paths['ETC']/'hub.json','hub')
        pc=n.load_config(paths['ETC']/'mbdev.publisher.json','publisher')
        remote=n.load_config(paths['BOT_HOME']/'network-stats-epiknet.private.json','publisher')
        self.assertNotEqual(pc['token'],remote['token'])
        self.assertEqual(hashlib.sha256(remote['token'].encode()).hexdigest(),hub['streams']['epiknet']['token_sha256'])
        self.assertEqual((paths['BOT_HOME']/'network-stats-epiknet.private.json').stat().st_mode&0o777,0o600)
        self.assertIn('Include /etc/apache2/mediabot-network-stats.conf',vhost.read_text())
        self.assertTrue((paths['APP']/'static/dashboard.js').is_file())
        self.assertTrue(any(x[:2]==['runuser','-u'] for x in calls))
        self.assertFalse(any('mediabot@dev.service' in x or 'mediabot@nbot.service' in x for x in calls))

    def test_setup_tls_failure_restores_files_without_erasing_history(self):
        paths,calls,vhost,original=self.exercise_setup(fail=True)
        self.assertEqual(vhost.read_text(),original)
        self.assertFalse((paths['ETC']/'hub.json').exists())
        self.assertFalse((paths['UNITS']/'mediabot-network-stats.service').exists())
        self.assertFalse((paths['BOT_HOME']/'network-stats-epiknet.private.json').exists())
        self.assertTrue(paths['DATA'].is_dir())
        self.assertEqual(len(list(paths['BACKUPS'].iterdir())),1)

    def test_setup_hub_permissions_with_private_umask(self):
        original=os.umask(0o077)
        try:
            paths,_,_,_=self.exercise_setup(repeat=True)
        finally:
            observed=os.umask(original)
        self.assertEqual(observed,0o077,'setup does not relax the caller umask')
        for directory in (paths['APP'],paths['APP']/'static',paths['ETC']):
            self.assertEqual(directory.stat().st_mode&0o777,0o755)
        self.assertEqual(paths['DATA'].stat().st_mode&0o777,0o750)
        self.assertEqual(paths['PUBLISHER_DATA'].stat().st_mode&0o777,0o700)
        self.assertEqual((paths['ETC']/'hub.json').stat().st_mode&0o777,0o640)
        self.assertEqual((paths['ETC']/'mbdev.publisher.json').stat().st_mode&0o777,0o600)
        self.assertEqual((paths['BOT_HOME']/'network-stats-epiknet.private.json').stat().st_mode&0o777,0o600)

    def test_setup_remote_publisher_permissions_with_private_umask(self):
        original=os.umask(0o077)
        try:
            paths,calls,_,_=self.exercise_setup(repeat=True,role='publisher')
        finally:
            observed=os.umask(original)
        self.assertEqual(observed,0o077)
        for directory in (paths['APP'],paths['APP']/'static',paths['ETC']):
            self.assertEqual(directory.stat().st_mode&0o777,0o755)
        self.assertEqual(paths['PUBLISHER_DATA'].stat().st_mode&0o777,0o700)
        self.assertEqual((paths['ETC']/'epiknet.publisher.json').stat().st_mode&0o777,0o600)
        self.assertFalse((paths['ETC']/'hub.json').exists())
        self.assertFalse(any('apache2ctl' in cmd or 'mediabot@nbot.service' in cmd for cmd in calls))

    def test_setup_managed_directory_rejects_symlinks(self):
        outside=self.root/'outside';outside.mkdir(mode=0o700)
        alias=self.root/'alias';alias.symlink_to(outside,target_is_directory=True)
        with patch.object(setup.os,'chown') as chown:
            with self.assertRaises(ValueError):setup.managed_directory(alias/'static',0o755,(0,0))
        chown.assert_not_called()
        self.assertFalse((outside/'static').exists())
        self.assertEqual(outside.stat().st_mode&0o777,0o700)

    def test_setup_failure_diagnostic_keeps_arguments_and_output_private(self):
        failure=subprocess.CalledProcessError(7,['runuser','-u',self.token],output=self.token,stderr=self.token)
        message=setup.failure_message(failure)
        self.assertIn('runuser',message);self.assertIn('exit 7',message)
        self.assertNotIn(self.token,message);self.assertNotIn('-u',message)
        self.assertNotIn(self.token,setup.failure_message(PermissionError(self.token)))

    def test_generic_single_bot_profile(self):
        host,streams,local=setup.profile('https://irc.example.org',['network=Our network'],'network')
        self.assertEqual((host,streams,local),('irc.example.org',{'network':'Our network'},'network'))
        text='<VirtualHost *:443>\nServerName irc.example.org\n</VirtualHost>'
        self.assertIn('Include /etc/apache2/mediabot-network-stats.conf',setup.vhost_include(text,host))
        for specs in [['x=Name','x=Other'],['../x=Bad'],['x=']]:
            with self.assertRaises(ValueError):setup.profile('https://irc.example.org',specs,None)
        with self.assertRaises(ValueError):setup.profile('http://irc.example.org',None,None)

    def test_setup_proxy_boundaries_and_systemd(self):
        text=setup.proxy(['mbdev','epiknet']);self.assertIn('(?:/.*)?',text);self.assertNotIn('ProxyPass / ',text)
        self.assertIn('User=mediabot',setup.unit_publisher('mbdev'));self.assertIn('User=mbnetstats',setup.unit_hub())
        self.assertIn('OnUnitInactiveSec=30',setup.unit_timer('epiknet'));self.assertNotIn('token',setup.unit_publisher('epiknet'))

if __name__=='__main__':unittest.main()
