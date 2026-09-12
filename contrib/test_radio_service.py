#!/usr/bin/env python3
"""Offline behavioral regressions: no network, SQL server, downloader or audio mutation."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
import subprocess
import threading
import unittest
from unittest.mock import patch
import radio_service as radio


class Backend:
    def __init__(self):
        self.events, self.error, self.sent = [], None, 0
    def capacity(self):
        self.events.append('capacity')
    def resolve(self, job):
        self.events.append('catalogue')
        if self.error == 'catalogue':
            raise radio.RadioError('catalogue_failed')
        return dict(artist='Radiohead',title='Idioteque',folder='/music',filename='idioteque.mp3')
    def push(self, track):
        self.events.append('push')
        self.sent += 1
        if self.error == 'ack':
            raise OSError('lost after sending')
        return 42


class Contract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = 1000.
        self.secret = 'a'*64
        self.c = dict(database=str(Path(self.temp.name)/'jobs.sqlite'),
                      token_hashes={'dev':hashlib.sha256(self.secret.encode()).hexdigest(),
                                    'nbot':hashlib.sha256(b'b'*64).hexdigest()})
        self.backend = Backend()
        self.s = radio.Service(self.c,self.backend,clock=lambda:self.now)
    def tearDown(self):
        self.s.db.close()
        self.temp.cleanup()
    def body(self, n=1, **extra):
        return dict(dict(id=f'{n:032x}',caller=f'{n:064x}',channel='#radio',action='play',
                         query='https://youtu.be/abcdefghijk'),**extra)
    def api(self, method, path, data=None, secret=None, **extra):
        raw=json.dumps(data).encode() if data is not None else b''
        env=dict(REQUEST_METHOD=method,PATH_INFO=path,CONTENT_TYPE='application/json',
                 CONTENT_LENGTH=str(len(raw)),HTTP_AUTHORIZATION='Bearer '+(secret or self.secret),
                 **{'wsgi.input':io.BytesIO(raw)})
        env.update(extra)
        headers=[]
        response=b''.join(self.s(env,lambda status,h:headers.append((status,h))))
        return int(headers[0][0].split()[0]), json.loads(response)
    def test_acceptance_has_no_side_effect_before_worker(self):
        status,result=self.api('POST','/v1/requests',self.body())
        self.assertEqual((status,result['state']),(202,'pending'))
        self.assertEqual(self.backend.events,[])
    def test_catalogue_precedes_push_and_success_requires_ack(self):
        self.s.submit('dev',self.body()); self.s.work_once()
        self.assertEqual(self.backend.events,['capacity','catalogue','capacity','push'])
        self.assertEqual(self.s.status('dev',self.body()['id'])['rid'],42)
    def test_db_failure_never_pushes(self):
        self.backend.error='catalogue'
        self.s.submit('dev',self.body()); self.s.work_once()
        self.assertEqual(self.backend.sent,0)
        self.assertEqual(self.s.status('dev',self.body()['id'])['state'],'failed')
    def test_ambiguous_push_is_not_retried_after_restart_or_http_retry(self):
        self.backend.error='ack'; body=self.body()
        self.s.submit('dev',body); self.s.work_once()
        self.s.db.close(); self.s=radio.Service(self.c,self.backend,clock=lambda:self.now)
        self.assertEqual(self.s.submit('dev',body)['state'],'uncertain')
        self.assertFalse(self.s.work_once()); self.assertEqual(self.backend.sent,1)
    def test_crash_after_marking_submitting_is_uncertain(self):
        self.s.submit('dev',self.body()); self.s.update(self.body()['id'],state='submitting')
        self.s.db.close(); self.s=radio.Service(self.c,self.backend)
        self.assertEqual(self.s.status('dev',self.body()['id'])['state'],'uncertain')
        self.assertFalse(self.s.work_once())
    def test_working_restart_can_resume_before_any_push(self):
        self.s.submit('dev',self.body()); self.s.update(self.body()['id'],state='working')
        self.s.db.close(); self.s=radio.Service(self.c,self.backend)
        self.assertTrue(self.s.work_once()); self.assertEqual(self.backend.sent,1)
    def test_same_id_is_idempotent_even_during_cooldown(self):
        a=self.s.submit('dev',self.body())
        self.assertEqual(a,self.s.submit('dev',self.body()))
        self.s.work_once(); self.assertEqual(self.s.submit('dev',self.body())['state'],'queued')
        self.assertFalse(self.s.work_once())
    def test_conflicting_request_id(self):
        self.s.submit('dev',self.body())
        with self.assertRaises(radio.RadioError) as e:
            self.s.submit('nbot',self.body())
        self.assertEqual(e.exception.status,409)
    def test_remote_instance_cannot_read_other_request(self):
        self.s.submit('dev',self.body())
        self.assertEqual(self.api('GET','/v1/requests/'+self.body()['id'],secret='b'*64)[0],404)
    def test_distinct_tokens_authenticate_without_payload_instance(self):
        self.assertEqual(self.api('POST','/v1/requests',self.body(),secret='b'*64)[0],202)
        self.assertEqual(self.s.db.execute('SELECT instance FROM jobs').fetchone()[0],'nbot')
        self.assertEqual(self.api('POST','/v1/requests',self.body(2,instance='dev'))[0],400)
    def test_no_token_no_job(self):
        self.assertEqual(self.api('POST','/v1/requests',self.body(),secret='c'*64)[0],401)
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
    def test_duplicate_youtube_across_instances(self):
        self.s.submit('dev',self.body())
        with self.assertRaisesRegex(radio.RadioError,'duplicate_video'):
            self.s.submit('nbot',self.body(2))
    def test_caller_budget_applies_across_channels(self):
        self.s.submit('dev',self.body())
        with self.assertRaisesRegex(radio.RadioError,'request_pending'):
            self.s.submit('dev',self.body(2,caller=self.body()['caller'],channel='#else',action='rplay',query='Radiohead'))
    def test_global_capacity_is_shared(self):
        for n in range(6):
            self.s.submit('bot'+str(n),self.body(n+1,action='rplay',query='Radiohead'))
        with self.assertRaisesRegex(radio.RadioError,'service_queue_full'):
            self.s.submit('another',self.body(9,action='rplay',query='Radiohead'))
    def test_no_match_allows_a_corrected_search_after_five_seconds(self):
        body=self.body(action='rplay',query='Keziaj Jones')
        self.s.submit('dev',body)
        self.s.update(body['id'],state='failed',code='no_matching_track')
        self.now+=6
        result=self.s.submit('dev',self.body(2,caller=body['caller'],action='rplay',query='Keziah Jones'))
        self.assertEqual(result['state'],'pending')
    def test_remaining_cooldown_is_reported(self):
        self.s.submit('dev',self.body());self.s.work_once();self.now+=37
        status,result=self.api('POST','/v1/requests',self.body(2,caller=self.body()['caller'],action='rplay',query='Radiohead'))
        self.assertEqual((status,result['error'],result['retry_after']),(429,'caller_cooldown',83))
    def test_typo_is_briefly_throttled_then_corrected_track_is_queued(self):
        body=self.body(action='rplay',query='Keziaj Jones')
        with patch.object(self.backend,'resolve',side_effect=radio.RadioError('no_matching_track')):
            self.s.submit('dev',body); self.s.work_once()
        self.now+=2
        corrected=self.body(2,caller=body['caller'],action='rplay',query='Keziah Jones')
        self.assertEqual(self.api('POST','/v1/requests',corrected),
                         (429,{'error':'caller_cooldown','retry_after':3}))
        self.now+=3
        self.assertEqual(self.api('POST','/v1/requests',corrected)[0],202)
        self.s.work_once()
        self.assertEqual(self.backend.sent,1)
    def test_other_failures_keep_the_normal_budget(self):
        self.backend.error='catalogue'
        self.s.submit('dev',self.body()); self.s.work_once(); self.now+=10
        status,r=self.api('POST','/v1/requests',self.body(2,caller=self.body()['caller'],action='rplay',query='Keziah Jones'))
        self.assertEqual((status,r['retry_after']),(429,110))
    def test_matching_but_unreadable_track_is_not_reported_as_absent(self):
        b=radio.Backend({})
        rows=[dict(id_mp3=1,folder='/music',filename='track.mp3')]
        with patch.object(b,'catalogue',return_value={'tracks':rows}), patch.object(b,'audio',side_effect=PermissionError):
            with self.assertRaisesRegex(radio.RadioError,'catalogue_tracks_unavailable'):
                b.resolve({'action':'rplay','query':'Keziah Jones'})
    def test_no_rows_is_a_catalogue_miss(self):
        b=radio.Backend({})
        with patch.object(b,'catalogue',return_value={'tracks':[]}):
            with self.assertRaisesRegex(radio.RadioError,'no_matching_track'):
                b.resolve({'action':'rplay','query':'Unknown'})
    def test_channel_cooldown(self):
        self.s.submit('dev',self.body())
        with self.assertRaisesRegex(radio.RadioError,'channel_cooldown'):
            self.s.submit('dev',self.body(2,action='rplay',query='Idioteque'))
    def test_cooldown_expires(self):
        self.s.submit('dev',self.body()); self.s.work_once(); self.now+=121
        self.assertEqual(self.s.submit('dev',self.body(2,action='rplay',query='Idioteque'))['state'],'pending')
    def test_youtube_canonicalization(self):
        for url in ('https://youtu.be/abcdefghijk?t=20','https://www.youtube.com/watch?v=abcdefghijk',
                    'https://www.youtube.com/shorts/abcdefghijk'):
            self.assertEqual(radio.youtube_id(url),'abcdefghijk')
    def test_url_rejections(self):
        for url in ('file:///etc/passwd','http://youtu.be/abcdefghijk','https://youtube.com.evil/watch?v=abcdefghijk',
                    'https://evil@youtube.com/watch?v=abcdefghijk','https://youtu.be:443/abcdefghijk',
                    'https://youtube.com/watch?v=abcdefghijk&list=PL123','https://127.0.0.1/private',
                    'https://youtu.be/abcdefghijk\nqueue.skip','--exec rm'):
            with self.subTest(url=url),self.assertRaises((radio.RadioError,ValueError)):
                radio.youtube_id(url)
    def test_user_paths_and_admin_actions_are_rejected(self):
        for body in (self.body(action='skip'),self.body(path='/music/a.mp3'),self.body(owner=1),self.body(query='x\npush')):
            self.assertEqual(self.api('POST','/v1/requests',body)[0],400)
    def test_request_framing(self):
        self.assertEqual(self.api('POST','/v1/requests',self.body(),CONTENT_LENGTH='50000')[0],413)
        self.assertEqual(self.api('POST','/v1/requests',self.body(),HTTP_TRANSFER_ENCODING='chunked')[0],400)
        self.assertEqual(self.api('POST','/v1/requests',self.body(),CONTENT_TYPE='text/plain')[0],415)
    def test_health_does_not_touch_queue(self):
        self.assertEqual(self.api('GET','/v1/health'),(200,dict(ok=True,protocol=1)))
        self.assertEqual(self.backend.events,[])
    def test_public_status_has_no_paths_or_origin(self):
        self.s.submit('dev',self.body()); self.s.work_once()
        r=self.api('GET','/v1/requests/'+self.body()['id'])[1]
        self.assertEqual(set(r),{'id','state','code','title','rid'})
    def test_cached_file_must_be_in_approved_roots(self):
        p=Path(self.temp.name)/'outside.mp3'; p.write_bytes(b'a')
        b=radio.Backend(dict(music_roots=[str(p.parent/'allowed')]))
        with self.assertRaisesRegex(radio.RadioError,'unreadable_track'): b.audio(p)
    def test_symlink_audio_rejected_before_probe(self):
        p=Path(self.temp.name)/'real.mp3'; p.write_bytes(b'a')
        link=p.with_name('link.mp3'); link.symlink_to(p)
        with self.assertRaisesRegex(radio.RadioError,'unreadable_track'):
            radio.Backend(dict(music_roots=[self.temp.name])).audio(link)
    def test_duration_limit_on_cached_tracks(self):
        p=Path(self.temp.name)/'track.mp3'; p.write_bytes(b'a')
        with patch.object(radio,'run',return_value=b'{"format":{"duration":"901"},"streams":[{"codec_type":"audio","codec_name":"mp3"}]}'):
            with self.assertRaisesRegex(radio.RadioError,'track_too_long'):
                radio.Backend(dict(music_roots=[self.temp.name])).audio(p)

    def test_actual_http_client_round_trip(self):
        # Test-only HTTP server: the shipped daemon uses Waitress, never wsgiref.
        from wsgiref.simple_server import make_server, WSGIRequestHandler
        class Quiet(WSGIRequestHandler):
            def log_message(self,*args): pass
        with make_server('127.0.0.1',0,self.s,handler_class=Quiet) as server:
            thread=threading.Thread(target=server.handle_request);thread.start()
            code="""BEGIN { $INC{'Mediabot/Helpers.pm'}=__FILE__; }
use Mediabot::Radio::Public; use JSON::PP;
my $v=Mediabot::Radio::Public::call_api($ARGV[0],'a'x64,'POST','/v1/requests',decode_json(do{local $/;<STDIN>}));
print encode_json($v);
"""
            result=subprocess.run(['perl','-I.','-e',code,'http://127.0.0.1:'+str(server.server_port)],
                                  input=json.dumps(self.body()),text=True,capture_output=True,timeout=15)
            thread.join(timeout=2)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['state'],'pending')
            self.assertEqual(self.backend.sent,0)

    def test_download_catalogue_failure_preserves_reusable_mp3_and_cookies(self):
        incoming=Path(self.temp.name)/'incoming';incoming.mkdir(mode=0o2750);incoming.chmod(0o2750)
        cookies=Path(self.temp.name)/'private.cookies';cookies.write_text('original cookies')
        cookies.chmod(0o600)
        c=dict(incoming=str(incoming),music_roots=[str(incoming)],yt_dlp='/fake/yt-dlp',
               catalogue_owner=44,cookies=str(cookies))
        b=radio.Backend(c); downloads=[]; registrations=[]
        def operation(args,**kw):
            if args[0]=='/usr/bin/ffprobe':
                return b'{"format":{"duration":"180"},"streams":[{"codec_type":"audio","codec_name":"mp3"}]}'
            downloads.append(args)
            target=Path(kw['directory'])
            (target/'audio.mp3').write_bytes(b'fake audio')
            (target/'audio.info.json').write_text(json.dumps(dict(id='abcdefghijk',uploader='Artist',title='Song')))
            Path(args[args.index('--cookies')+1]).write_text('updated private copy')
            return b''
        def catalogue(action,**kw):
            registrations.append((action,kw))
            raise radio.RadioError('catalogue_failed')
        with patch.object(radio,'run',side_effect=operation),patch.object(b,'catalogue',side_effect=catalogue):
            for _ in range(2):
                with self.assertRaisesRegex(radio.RadioError,'catalogue_failed'): b.download('abcdefghijk')
        self.assertEqual(len(downloads),1,'Retry after DB failure reuses downloaded file')
        self.assertEqual(cookies.read_text(),'original cookies')
        self.assertEqual((incoming/'abcdefghijk.mp3').stat().st_mode&0o777,0o640)
        self.assertEqual(registrations[0][1]['owner'],44)
        self.assertEqual(registrations[0][1]['filename'],'abcdefghijk.mp3')
        self.assertEqual(downloads[0][-2:],['--','https://www.youtube.com/watch?v=abcdefghijk'])
        self.assertIn('--ignore-config',downloads[0]);self.assertIn('--no-plugin-dirs',downloads[0])
        self.assertFalse(any(p.name.startswith('.radio-') for p in incoming.iterdir()))

    def test_failed_worker_rejects_new_requests(self):
        self.s.worker_thread=threading.Thread()
        self.assertEqual(self.api('POST','/v1/requests',self.body())[0],503)
        self.assertEqual(self.s.db.execute('SELECT COUNT(*) FROM jobs').fetchone()[0],0)



class Hardening(unittest.TestCase):
    setUp = Contract.setUp
    tearDown = Contract.tearDown
    body = Contract.body
    api = Contract.api
    def test_rplay_same_track_across_instances_is_pushed_once(self):
        self.s.submit('dev', self.body(action='rplay', query='Artist'))
        self.s.work_once()
        self.now += 16
        other = self.body(2, action='rplay', query='Song')
        self.s.submit('nbot', other)
        self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.assertEqual(self.s.status('nbot', other['id'])['code'], 'duplicate_track')

    def test_play_and_rplay_use_the_same_video_claim(self):
        track = dict(id_youtube='abcdefghijk', artist='Artist', title='Song',
                     folder='/music', filename='track.mp3')
        with patch.object(self.backend, 'resolve', return_value=track):
            self.s.submit('dev', self.body())
            self.s.work_once()
            self.now += 16
            self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
            self.s.work_once()
        self.assertEqual(self.backend.sent, 1)

    def test_track_claim_survives_restart_and_ack_loss(self):
        self.backend.error = 'ack'
        self.s.submit('dev', self.body(action='rplay', query='Artist'))
        self.s.work_once()
        self.s.db.close()
        self.s = radio.Service(self.c, self.backend, clock=lambda: self.now)
        self.now += 16
        self.backend.error = None
        self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
        self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.assertEqual(self.s.status('nbot', self.body(2)['id'])['code'], 'duplicate_track')

    def test_existing_play_history_protects_first_rplay_after_upgrade(self):
        self.s.submit('dev', self.body())
        self.s.work_once()
        self.s.db.execute('DELETE FROM track_claims')
        self.s.db.commit()
        self.now += 16
        track = dict(id_youtube='abcdefghijk', artist='Artist', title='Song',
                     folder='/music', filename='track.mp3')
        with patch.object(self.backend, 'resolve', return_value=track):
            self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
            self.s.work_once()
        self.assertEqual(self.backend.sent, 1)

    def test_claim_expires_from_submission_not_acceptance(self):
        self.s.submit('dev', self.body(action='rplay', query='Artist'))
        self.now += 800
        self.s.work_once()
        self.now += 590
        self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
        self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.now += 11
        self.s.submit('another', self.body(3, action='rplay', query='Artist'))
        self.s.work_once()
        self.assertEqual(self.backend.sent, 2)

    def test_late_play_ack_keeps_video_deduplication_active(self):
        self.s.submit('dev', self.body())
        self.now += 800
        self.s.work_once()
        self.now += 1
        with self.assertRaisesRegex(radio.RadioError, 'duplicate_video'):
            self.s.submit('nbot', self.body(2))

    def test_failure_before_push_does_not_reserve_track(self):
        self.s.submit('dev', self.body(action='rplay', query='Artist'))
        original = self.s.update
        def update(job, **values):
            if values.get('state') == 'submitting':
                raise radio.RadioError('simulated_failure_before_push')
            return original(job, **values)
        with patch.object(self.s, 'update', side_effect=update):
            self.s.work_once()
        self.now += 16
        self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
        self.s.work_once()
        self.assertEqual(self.backend.sent, 1)

    def test_youtube_pause_survives_restart_but_cached_tracks_work(self):
        self.s.submit('dev', self.body())
        with patch.object(self.backend, 'resolve', side_effect=radio.RadioError('youtube_auth_required')):
            self.s.work_once()
        self.s.db.close()
        self.s = radio.Service(self.c, self.backend, clock=lambda: self.now)
        with self.assertRaisesRegex(radio.RadioError, 'youtube_paused'):
            self.backend.download_guard()
        self.now += 16
        self.s.submit('nbot', self.body(2, action='rplay', query='Artist'))
        self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.now += 285
        self.backend.download_guard()

    def test_paused_download_never_launches_downloader(self):
        b = radio.Backend(dict(incoming=self.temp.name))
        b.download_guard = lambda: (_ for _ in ()).throw(radio.RadioError('youtube_paused'))
        with patch.object(radio, 'run', side_effect=AssertionError('must not launch')):
            with self.assertRaisesRegex(radio.RadioError, 'youtube_paused'):
                b.download('abcdefghijk')

    def test_other_download_errors_do_not_pause_youtube(self):
        self.s.submit('dev', self.body())
        with patch.object(self.backend, 'resolve', side_effect=radio.RadioError('youtube_unavailable')):
            self.s.work_once()
        self.backend.download_guard()
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM download_pause').fetchone()[0], 0)

    def test_rate_limit_pause_is_fifteen_minutes(self):
        self.s.submit('dev', self.body())
        with patch.object(self.backend, 'resolve', side_effect=radio.RadioError('youtube_rate_limited')):
            self.s.work_once()
        self.now += 899
        with self.assertRaisesRegex(radio.RadioError, 'youtube_paused'):
            self.backend.download_guard()
        self.now += 1
        self.backend.download_guard()

    def test_error_codes_never_contain_stderr_secrets(self):
        import sys
        cases = [("Sign in to confirm you're not a bot", 'youtube_auth_required'),
                 ('The provided YouTube account cookies are no longer valid', 'youtube_auth_required'),
                 ('HTTP Error 429: Too Many Requests', 'youtube_rate_limited'),
                 ('Video unavailable', 'youtube_unavailable'),
                 ('Did not get any data blocks', 'youtube_no_data'),
                 ('Other error', 'download_failed')]
        for text, expected in cases:
            with self.subTest(expected=expected):
                code = 'import sys;sys.stderr.write(' + repr(text + ' secret-cookie https://private.example/?token=SECRET') + ');sys.exit(1)'
                with self.assertRaises(radio.RadioError) as error:
                    radio.run([sys.executable, '-c', code], error_classifier=radio.download_error)
                self.assertEqual(error.exception.code, expected)
                self.assertNotIn('SECRET', str(error.exception))

    def test_exited_leader_does_not_leave_descendant_running(self):
        import sys, time
        marker = Path(self.temp.name) / 'escaped'
        started = Path(self.temp.name) / 'started'
        code = ('import os,time; p=os.fork(); '
                '\nif p: os._exit(0)\nopen(' + repr(str(started)) + ",'w').write('ready')\n"
                'time.sleep(.7)\nopen(' + repr(str(marker)) + ",'w').write('bad')\n")
        with self.assertRaisesRegex(radio.RadioError, 'operation_timeout'):
            radio.run([sys.executable, '-c', code], timeout=.3)
        self.assertTrue(started.exists(), 'the descendant actually started before the deadline')
        time.sleep(.5)
        self.assertFalse(marker.exists(), 'descendant killed even after the group leader exits')

    def test_catalogue_scan_has_a_total_time_budget(self):
        b = radio.Backend({})
        rows = [dict(id_mp3=i, folder='/music', filename=str(i)+'.mp3') for i in range(200)]
        with patch.object(b, 'catalogue', return_value={'tracks': rows}), \
             patch.object(b, 'audio', side_effect=PermissionError) as audio, \
             patch.object(radio.time, 'monotonic', side_effect=[0, 1, 10, 20, 31]):
            with self.assertRaisesRegex(radio.RadioError, 'catalogue_scan_timeout'):
                b.resolve({'action': 'rplay', 'query': 'Artist'})
        self.assertEqual(audio.call_count, 3)

    def test_metadata_size_symlinks_and_shared_inodes_are_rejected(self):
        import os
        p = Path(self.temp.name) / 'data'
        p.write_bytes(b'123456789')
        with self.assertRaisesRegex(radio.RadioError, 'unsafe_metadata'):
            radio.bounded_file(p, 8)
        link = p.with_name('link'); link.symlink_to(p)
        with self.assertRaises(OSError):
            radio.bounded_file(link, 100)
        os.link(p, p.with_name('hardlink'))
        with self.assertRaisesRegex(radio.RadioError, 'unsafe_metadata'):
            radio.bounded_file(p, 100)

    def test_private_cookie_permissions_are_checked(self):
        p = Path(self.temp.name) / 'cookies'
        p.write_bytes(b'private-cookie'); p.chmod(0o644)
        with self.assertRaisesRegex(radio.RadioError, 'private_file_required'):
            radio.bounded_file(p, 100, private=True)
        p.chmod(0o600)
        self.assertEqual(radio.bounded_file(p, 100, private=True), b'private-cookie')

    def test_legacy_metadata_remains_usable(self):
        p = Path(self.temp.name) / 'abcdefghijk.radio.json'
        p.write_text(json.dumps(dict(id='abcdefghijk', artist='Artist', title='Song')))
        meta = radio.Backend({}).cached_metadata(p, p.with_suffix('.mp3'), 'abcdefghijk')
        self.assertEqual(meta['title'], 'Song')

    def test_new_cache_fingerprint_detects_replaced_audio(self):
        p = Path(self.temp.name) / 'abcdefghijk.radio.json'
        audio = Path(self.temp.name) / 'abcdefghijk.mp3'; audio.write_bytes(b'original')
        p.write_text(json.dumps(dict(id='abcdefghijk', artist='Artist', title='Song',
                                    sha256=hashlib.sha256(b'original').hexdigest(), size=8)))
        b = radio.Backend({})
        b.cached_metadata(p, audio, 'abcdefghijk')
        audio.write_bytes(b'replaced')
        with self.assertRaisesRegex(radio.RadioError, 'cached_audio_changed'):
            b.cached_metadata(p, audio, 'abcdefghijk')

    def test_invalid_video_never_touches_download_storage(self):
        for video in ('../outside', 'abc', 'abcdefghijk\n'):
            with self.assertRaises(radio.RadioError):
                radio.Backend({}).download(video)

    def test_ambiguous_youtube_urls_rejected(self):
        for url in ('https://youtube.com/watch?v=abcdefghijk&v=01234567890',
                    'https://youtube.com/watch?v=abcdefghijk&list=',
                    'https://youtu.be/abcde\nfghijk',
                    'https://youtu.be/abcdefghijk\t'):
            with self.assertRaises(radio.RadioError):
                radio.youtube_id(url)

    def test_real_mp3_probed_offline(self):
        import shutil
        if not shutil.which('ffmpeg') or not Path('/usr/bin/ffprobe').exists():
            self.skipTest('ffmpeg/ffprobe unavailable in this environment')
        p = Path(self.temp.name) / 'tone.mp3'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.1',
                        '-c:a', 'libmp3lame', str(p)], check=True, capture_output=True, timeout=10)
        b = radio.Backend(dict(music_roots=[self.temp.name]))
        self.assertEqual(b.audio(p), p)
        p.write_text('#EXTM3U\nhttp://127.0.0.1:1/should-not-fetch\n')
        with self.assertRaises(radio.RadioError):
            b.audio(p)


if __name__=='__main__':
    unittest.main(verbosity=1)
