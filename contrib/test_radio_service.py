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
from unittest.mock import patch, Mock
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
            (target/'audio.info.json').write_text(json.dumps(dict(id='abcdefghijk',uploader='Artist',title='Artist - Song')))
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
        self.assertEqual(registrations[0][1]['title'],'Song')
        self.assertEqual(json.loads((incoming/'abcdefghijk.radio.json').read_text())['title'],'Song')
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


class TextPlay(unittest.TestCase):
    setUp = Contract.setUp
    tearDown = Contract.tearDown
    body = Contract.body
    api = Contract.api

    @staticmethod
    def entry(video='abcdefghijk', **extra):
        return dict(dict(id=video, ie_key='Youtube', duration=295,
                         url='https://www.youtube.com/watch?v='+video), **extra)

    def test_text_acceptance_does_not_search_in_http_handler(self):
        self.backend.search = Mock(return_value='abcdefghijk')
        status, result = self.api('POST', '/v1/requests', self.body(query='Mickael Jackson Billie Jean'))
        self.assertEqual((status, result['state']), (202, 'pending'))
        self.backend.search.assert_not_called()
        self.assertEqual(self.backend.sent, 0)

    def test_search_pins_id_before_resolve_then_queues_for_remote_client(self):
        self.backend.search = Mock(return_value='abcdefghijk')
        resolve = self.backend.resolve
        def check(job):
            saved = self.s.db.execute('SELECT video,state FROM jobs WHERE id=?', (job['id'],)).fetchone()
            self.assertEqual(tuple(saved), ('abcdefghijk', 'working'))
            self.assertEqual(job['video'], 'abcdefghijk')
            return resolve(job)
        self.backend.resolve = check
        self.s.submit('nbot', self.body(query='Michael Jackson Billie Jean'))
        self.s.work_once()
        self.backend.search.assert_called_once_with('Michael Jackson Billie Jean')
        self.assertEqual(self.s.status('nbot', self.body()['id'])['state'], 'queued')
        self.assertEqual(self.backend.events, ['capacity', 'catalogue', 'capacity', 'push'])

    def test_restart_after_selection_never_searches_again(self):
        self.s.submit('dev', self.body(query='Michael Jackson Billie Jean'))
        self.s.update(self.body()['id'], state='working', video='abcdefghijk')
        self.s.db.close()
        self.s = radio.Service(self.c, self.backend, clock=lambda:self.now)
        self.backend.search = Mock(side_effect=AssertionError('must retain selected video'))
        self.s.work_once()
        self.backend.search.assert_not_called()
        self.assertEqual(self.backend.sent, 1)

    def test_http_retry_never_researches_or_pushes_twice(self):
        self.backend.search = Mock(return_value='abcdefghijk')
        body = self.body(query='Michael Jackson Billie Jean')
        self.s.submit('dev', body); self.s.work_once()
        self.assertEqual(self.s.submit('dev', body)['state'], 'queued')
        self.assertFalse(self.s.work_once())
        self.backend.search.assert_called_once()
        self.assertEqual(self.backend.sent, 1)

    def test_search_result_deduplicates_url_before_download(self):
        self.s.submit('dev', self.body()); self.s.work_once()
        self.now += 16
        self.backend.search = Mock(return_value='abcdefghijk')
        self.backend.resolve = Mock(side_effect=AssertionError('duplicate must not download'))
        self.s.submit('nbot', self.body(2, query='Michael Jackson Billie Jean'))
        self.s.work_once()
        self.assertEqual(self.s.status('nbot', self.body(2)['id'])['code'], 'duplicate_video')
        self.backend.resolve.assert_not_called()
        self.assertEqual(self.backend.sent, 1)

    def test_two_different_searches_for_same_video_push_once(self):
        self.backend.search = Mock(return_value='abcdefghijk')
        self.s.submit('dev', self.body(query='Michael Jackson Billie Jean'))
        self.s.submit('nbot', self.body(2, query='Billie Jean Michael Jackson'))
        self.s.work_once(); self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.assertEqual(self.s.status('nbot', self.body(2)['id'])['code'], 'duplicate_video')

    def test_play_search_and_rplay_share_final_track_claim(self):
        self.backend.resolve = Mock(return_value=dict(artist='Artist', title='Track',
                                                      path='/music/track.mp3', id_youtube='abcdefghijk'))
        self.s.submit('nbot', self.body(action='rplay', query='Track')); self.s.work_once()
        self.backend.search = Mock(return_value='abcdefghijk')
        self.s.submit('dev', self.body(2, query='Artist Track')); self.s.work_once()
        self.assertEqual(self.backend.sent, 1)
        self.assertEqual(self.s.status('dev', self.body(2)['id'])['code'], 'duplicate_track')

    def test_search_ack_loss_retains_existing_uncertainty_contract(self):
        self.backend.search = Mock(return_value='abcdefghijk'); self.backend.error = 'ack'
        body = self.body(query='Artist Track')
        self.s.submit('dev', body); self.s.work_once()
        self.s.db.close(); self.s = radio.Service(self.c, self.backend, clock=lambda:self.now)
        self.assertFalse(self.s.work_once())
        self.assertEqual(self.s.submit('dev', body)['state'], 'uncertain')
        self.assertEqual(self.backend.sent, 1)

    def test_rplay_never_searches_youtube(self):
        self.backend.search = Mock(side_effect=AssertionError('rplay stays catalogue only'))
        self.s.submit('dev', self.body(action='rplay', query='Radiohead')); self.s.work_once()
        self.backend.search.assert_not_called()
        self.assertEqual(self.backend.sent, 1)

    def test_url_play_does_not_search(self):
        self.backend.search = Mock(side_effect=AssertionError('URL pins identity directly'))
        self.s.submit('dev', self.body()); self.s.work_once()
        self.backend.search.assert_not_called()

    def test_unsafe_input_cannot_become_an_extractor_or_local_path(self):
        for query in ('http://youtu.be/abcdefghijk', 'file:///etc/passwd', '//127.0.0.1',
                      'ytsearch100:music', '/home/music.mp3', '../music.mp3', '--exec id',
                      'https://evil.test/x', 'https://youtube.com/watch?v=abcdefghijk&list=abc',
                      'https://youtu.be:bad/abcdefghijk', 'Artist\nTrack', 'Artist\u202eTrack',
                      'Artist\ud800Track', 'www.youtube.com/watch?v=abcdefghijk'):
            with self.subTest(query=query):
                self.assertEqual(self.api('POST', '/v1/requests', self.body(query=query))[0], 400)
        self.assertEqual(self.s.db.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)

    def test_quotes_accents_and_shell_characters_remain_search_words(self):
        for query in ('Björk Jóga', 'AC/DC Back in Black', 'Artist "Track"', "Guns N’ Roses", 'Artist $(id); Track'):
            self.assertEqual(radio.play_input(query), '')

    def test_first_eligible_video_in_relevance_order_is_selected(self):
        entries = [self.entry(is_live=True), self.entry(duration=901), self.entry(duration=None),
                   self.entry('ABCDEFGHIJK'), self.entry('01234567890')]
        self.assertEqual(radio.search_video(dict(_type='playlist', entries=entries), 900), 'ABCDEFGHIJK')

    def test_invalid_duration_identity_live_and_channel_are_skipped(self):
        for changed in (dict(duration=True), dict(duration=float('nan')), dict(duration=float('inf')),
                        dict(duration=0), dict(id='../etc/passwd'), dict(ie_key='YoutubeTab'),
                        dict(live_status='is_upcoming'), dict(live_status='post_live')):
            with self.subTest(changed=changed), self.assertRaisesRegex(radio.RadioError, 'no_youtube_match'):
                radio.search_video(dict(_type='playlist', entries=[self.entry(**changed)]), 900)

    def test_invalid_search_envelope_fails_without_taking_sixth_result(self):
        for result in (None, [], {}, dict(_type='video', entries=[]),
                       dict(_type='playlist', entries=[self.entry()]*6)):
            with self.assertRaisesRegex(radio.RadioError, 'youtube_search_failed'):
                radio.search_video(result, 900)

    def test_empty_search_allows_correction_after_five_seconds(self):
        self.backend.search = Mock(side_effect=radio.RadioError('no_youtube_match', 404))
        self.s.submit('dev', self.body(query='Typo')); self.s.work_once()
        self.now += 4
        with self.assertRaisesRegex(radio.RadioError, 'caller_cooldown'):
            self.s.submit('dev', self.body(2, caller=self.body()['caller'], query='Corrected'))
        self.now += 1
        self.assertEqual(self.s.submit('dev', self.body(2, caller=self.body()['caller'], query='Corrected'))['state'], 'pending')
        self.assertEqual(self.backend.sent, 0)

    def test_search_failure_preserves_normal_cooldown(self):
        self.backend.search = Mock(side_effect=radio.RadioError('youtube_search_failed', 503))
        self.s.submit('dev', self.body(query='Artist Track')); self.s.work_once(); self.now += 6
        with self.assertRaisesRegex(radio.RadioError, 'caller_cooldown'):
            self.s.submit('dev', self.body(2, caller=self.body()['caller'], query='Artist Track'))

    def test_search_auth_failure_pauses_youtube_durably(self):
        self.backend.search = Mock(side_effect=radio.RadioError('youtube_auth_required', 503))
        self.s.submit('dev', self.body(query='Artist Track')); self.s.work_once()
        self.s.db.close(); self.s = radio.Service(self.c, self.backend, clock=lambda:self.now)
        with self.assertRaisesRegex(radio.RadioError, 'youtube_paused'):
            self.s.download_guard()
        self.assertEqual(self.backend.sent, 0)

    def test_paused_search_cannot_launch_downloader(self):
        backend = radio.Backend({'incoming':self.temp.name})
        backend.download_guard = Mock(side_effect=radio.RadioError('youtube_paused', 503))
        with patch.object(radio, 'run') as execute, self.assertRaisesRegex(radio.RadioError, 'youtube_paused'):
            backend.search('Artist Track')
        execute.assert_not_called()

    def test_native_search_arguments_are_bounded_and_cookie_copy_is_private(self):
        cookies = Path(self.temp.name)/'original.cookies'
        cookies.write_bytes(b'private fixture'); cookies.chmod(0o600)
        config = dict(incoming=self.temp.name, yt_dlp='/tools/yt-dlp', cookies=str(cookies),
                      js_runtime='node:/tools/node', remote_components='ejs:github')
        backend = radio.Backend(config)
        query = 'Björk "Jóga" $(id); Track'
        paths = []
        def execute(args, **kw):
            self.assertEqual(args[-2:], ['--', 'ytsearch5:'+query])
            for flag, value in (('--use-extractors','youtube:search'), ('--playlist-end','5'),
                                ('--js-runtimes','node:/tools/node')):
                self.assertEqual(args[args.index(flag)+1], value)
            for flag in ('--ignore-config','--no-plugin-dirs','--flat-playlist','--skip-download',
                         '--dump-single-json','--no-mark-watched'):
                self.assertIn(flag, args)
            self.assertEqual(kw['timeout'], 30)
            p = Path(args[args.index('--cookies')+1]); paths.append(p)
            self.assertNotEqual(p, cookies)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            self.assertEqual(p.read_bytes(), cookies.read_bytes())
            p.write_bytes(b'rotated by child')
            return json.dumps(dict(_type='playlist',entries=[self.entry()])).encode()
        with patch.object(radio, 'run', side_effect=execute):
            self.assertEqual(backend.search(query), 'abcdefghijk')
        self.assertEqual(cookies.read_bytes(), b'private fixture')
        self.assertFalse(paths[0].exists())

    def test_selected_video_reuses_catalogue_without_download(self):
        backend = radio.Backend({'music_roots':['/music']})
        track = dict(folder='/music',filename='track.mp3',artist='Artist',title='Track')
        with patch.object(backend, 'catalogue', return_value={'tracks':[track]}) as catalogue, \
             patch.object(backend, 'audio', return_value=Path('/music/track.mp3')), \
             patch.object(backend, 'download') as download:
            result = backend.resolve(dict(action='play',query='Artist Track',video='abcdefghijk'))
        catalogue.assert_called_once_with('youtube', youtube='abcdefghijk')
        download.assert_not_called()
        self.assertEqual(result['title'], 'Track')


class MetadataContract(unittest.TestCase):
    def test_duplicate_artist_prefixes_keep_recording_suffixes(self):
        cases = (
            ('Michael Jackson', 'Michael Jackson - Billie Jean (Official Video)', 'Billie Jean (Official Video)'),
            ('Paul Simon', 'Paul Simon - You Can Call Me Al (Official Video)', 'You Can Call Me Al (Official Video)'),
            ('AC/DC', 'AC/DC — Back in Black (Live)', 'Back in Black (Live)'),
            ('A+B', 'a+b – Song (Remaster)', 'Song (Remaster)'),
            ('Björk', 'Bjo\u0308rk | Jóga', 'Jóga'),
            ('Artist', 'Artist: Song', 'Song'),
            ('Artist', 'Artist - Artist - Song', 'Song'),
        )
        for artist, title, expected in cases:
            with self.subTest(title=title):
                a, t = radio.metadata_labels(dict(artist=artist, title=title))
                self.assertEqual(t, expected)
                self.assertEqual(radio.metadata_labels(dict(artist=a,title=t)), (a,t))

    def test_titles_without_exact_separated_prefix_are_preserved(self):
        for artist, title in (('Talk Talk','Talk Talk'), ('Artist','Artist - '),
                              ('Paul Simon','Simon & Garfunkel - The Boxer'),
                              ('The','The-The Song'), ('Artist','Other Artist - Song'),
                              ('Artist','Artist feat. Guest - Song'), ('','Artist - Song')):
            with self.subTest(title=title):
                self.assertEqual(radio.metadata_labels(dict(artist=artist,title=title)),
                                 (artist,title.strip()))

    def test_cached_catalogue_labels_match_notice_queue_and_player_without_writes(self):
        with tempfile.TemporaryDirectory() as area:
            b = radio.Backend({'queue_id':'request_queue'})
            s = radio.Service({'database':str(Path(area)/'jobs.sqlite')}, b)
            path = Path(area)/'cached.mp3'; path.write_bytes(b'existing fixture')
            sidecar = path.with_suffix('.radio.json');sidecar.write_bytes(b'original metadata fixture')
            original = dict(path=str(path),artist='Paul Simon',title='Paul Simon - You Can Call Me Al (Official Video)')
            before = dict(original)
            try:
                with patch.object(b,'capacity'), patch.object(b,'resolve',return_value=original), \
                     patch.object(b,'audio',return_value=path), patch.object(b,'command',return_value='42') as command:
                    s.submit('nbot',dict(id='a'*32,caller='b'*64,channel='#radio',action='rplay',query='Paul Simon'))
                    s.work_once()
                self.assertEqual(original,before)
                self.assertEqual(s.status('nbot','a'*32)['title'],'Paul Simon — You Can Call Me Al (Official Video)')
                self.assertIn('artist="Paul Simon",title="You Can Call Me Al (Official Video)"',command.call_args.args[0])
                self.assertEqual(radio.queue_title('artist="Paul Simon"\ntitle="Paul Simon - You Can Call Me Al (Official Video)"'),
                                 'Paul Simon — You Can Call Me Al (Official Video)')
                self.assertEqual(path.read_bytes(),b'existing fixture')
                self.assertEqual(sidecar.read_bytes(),b'original metadata fixture')
            finally:s.db.close()

    def test_remote_and_local_workers_send_metadata_over_real_loopback_socket(self):
        import socket
        for instance, action in (('dev', 'play'), ('nbot', 'rplay')):
            with self.subTest(instance=instance), tempfile.TemporaryDirectory() as area, socket.socket() as server:
                server.bind(('127.0.0.1', 0)); server.listen(1); server.settimeout(5)
                events = []
                def receive():
                    with server.accept()[0] as peer:
                        peer.settimeout(5)
                        data = bytearray()
                        while not data.endswith(b'\n'):
                            chunk = peer.recv(4096)
                            if not chunk or len(data) > 16384:
                                break
                            data.extend(chunk)
                        events.append(bytes(data))
                        peer.sendall(b'42\r\nEND\r\n')
                thread = threading.Thread(target=receive, daemon=True)
                thread.start()
                path = Path(area)/'old.mp3'
                path.write_bytes(b'existing audio fixture')
                fingerprint = hashlib.sha256(path.read_bytes()).hexdigest()
                b = radio.Backend({'queue_id': 'request_queue', 'liquidsoap_port': server.getsockname()[1]})
                service = radio.Service({'database': str(Path(area)/'jobs.sqlite')}, b)
                body = dict(id='a'*32, caller='b'*64, channel='#radio', action=action,
                            query='https://youtu.be/abcdefghijk' if action=='play' else 'Stevie Wonder')
                track = dict(path=str(path), artist='Stevie Wonder', title='Superstition')
                try:
                    with patch.object(b, 'capacity'), patch.object(b, 'resolve', return_value=track), patch.object(b, 'audio', return_value=path):
                        service.submit(instance, body)
                        service.work_once()
                    thread.join(6)
                    self.assertFalse(thread.is_alive())
                    self.assertEqual(service.status(instance, body['id'])['state'], 'queued')
                    self.assertEqual(events, [('request_queue.push annotate:artist="Stevie Wonder",title="Superstition":'+str(path)+'\n').encode()])
                    self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), fingerprint)
                finally:
                    service.db.close()

    def test_catalogue_title_is_attached_to_numeric_acknowledged_request(self):
        b = radio.Backend({'queue_id': 'request_queue'})
        p = Path('/music/ftdZ363R9kQ.mp3')
        track = dict(path=str(p), artist='Stevie Wonder', title='Superstition')
        with patch.object(b, 'audio', return_value=p) as audio, patch.object(b, 'command', return_value='42') as command:
            self.assertEqual(b.push(track), 42)
        audio.assert_called_once_with(p)
        command.assert_called_once_with(
            'request_queue.push annotate:artist="Stevie Wonder",title="Superstition":/music/ftdZ363R9kQ.mp3')

    def test_quotes_backslashes_and_interpolation_are_literal(self):
        value = 'A "quote", a \\path : #{1 + 2}'
        self.assertEqual(radio.liquidsoap_string(value),
                         '"A \\"quote\\", a \\\\path : \\x23{1 + 2}"')

    def test_controls_cannot_introduce_a_second_telnet_command(self):
        uri = radio.track_uri(Path('/music/a.mp3'),
                              dict(artist='A\r\nrequest_queue.skip', title='B\x00\t\x7f\x85C'))
        self.assertNotRegex(uri, r'[\x00-\x1f\x7f-\x9f]')
        self.assertIn('title="B    C"', uri)

    def test_utf8_punctuation_remains_readable(self):
        uri = radio.track_uri(Path('/music/été, live.mp3'),
                              dict(artist="Björk & L’été", title='東京 — 🪄'))
        self.assertEqual(uri, 'annotate:artist="Björk & L’été",title="東京 — 🪄":/music/été, live.mp3')

    def test_metadata_cannot_add_temporary_or_a_different_uri(self):
        uri = radio.track_uri(Path('/music/a.mp3'), dict(artist='A',
                              title='x",temporary="true":https://example.invalid/evil'))
        self.assertIn('title="x\\",temporary=\\"true\\":https://example.invalid/evil"', uri)
        self.assertTrue(uri.endswith(':/music/a.mp3'))

    def test_missing_titles_use_filename_and_metadata_is_bounded(self):
        self.assertEqual(radio.track_uri(Path('/music/song.mp3'), {'artist': None, 'title': None}),
                         'annotate:artist="",title="song":/music/song.mp3')
        uri = radio.track_uri(Path('/music/a.mp3'), dict(artist='a'*999, title='b'*999))
        self.assertIn('artist="'+'a'*255+'"', uri)
        self.assertIn('title="'+'b'*255+'"', uri)

    def test_invalid_audio_never_reaches_queue(self):
        b = radio.Backend({'queue_id': 'request_queue'})
        with patch.object(b, 'audio', side_effect=radio.RadioError('unreadable_track')), patch.object(b, 'command') as command:
            with self.assertRaisesRegex(radio.RadioError, 'unreadable_track'):
                b.push(dict(path='/music/a.mp3', artist='A', title='B'))
            command.assert_not_called()

    def test_invalid_unicode_never_reaches_queue(self):
        b = radio.Backend({'queue_id': 'request_queue'})
        with patch.object(b, 'audio', return_value=Path('/music/a.mp3')), patch.object(b, 'command') as command:
            with self.assertRaisesRegex(radio.RadioError, 'unsafe_metadata'):
                b.push(dict(path='/music/a.mp3', artist='A', title='bad\ud800'))
            command.assert_not_called()

    def test_lost_acknowledgement_is_not_retried_by_metadata_push(self):
        b = radio.Backend({'queue_id': 'request_queue'})
        with patch.object(b, 'audio', return_value=Path('/music/a.mp3')), patch.object(b, 'command', side_effect=OSError) as command:
            with self.assertRaises(OSError):
                b.push(dict(path='/music/a.mp3', artist='A', title='B'))
            self.assertEqual(command.call_count, 1)


class QueueView(unittest.TestCase):
    def test_pending_ids_are_read_twice_and_only_labels_are_exposed(self):
        b=radio.Backend({'queue_id':'request_queue'})
        values=['8 9', 'artist="Björk"\ntitle="東京"\nfilename="/private/secret.mp3"\nrid="8"',
                'title="Second"\ninitial_uri="secret"', '8 9']
        with patch.object(b,'command',side_effect=values) as command:
            result=b.queue_view()
        self.assertEqual(result,{'waiting':[{'title':'Björk — 東京'},{'title':'Second'}],'total':2})
        self.assertEqual([c.args[0] for c in command.call_args_list],
                         ['request_queue.queue','request.metadata 8','request.metadata 9','request_queue.queue'])
        self.assertEqual(len({c.kwargs['deadline'] for c in command.call_args_list}),1)

    def test_transition_drops_old_head_and_uses_new_metadata(self):
        b=radio.Backend({'queue_id':'q'})
        with patch.object(b,'command',side_effect=['1','title="Old"','2','2','title="New"','2']):
            self.assertEqual(b.queue_view()['waiting'],[{'title':'New'}])

    def test_twice_changing_queue_never_claims_empty_or_stable(self):
        b=radio.Backend({'queue_id':'q'})
        with patch.object(b,'command',side_effect=['1','','2','2','','3']):
            with self.assertRaisesRegex(radio.RadioError,'queue_changing'):b.queue_view()

    def test_no_queue_metadata_and_invalid_ids_fail_closed(self):
        b=radio.Backend({'queue_id':'q'})
        for bad in ('ERROR: unknown command','1 1','1\nq.skip','-1','1;2','12345678901'):
            with self.subTest(bad=bad), patch.object(b,'command',return_value=bad) as command:
                with self.assertRaises(radio.RadioError):b.queue_view()
                self.assertEqual(command.call_count,1)

    def test_missing_or_unresolved_title_never_falls_back_to_path(self):
        for text in ('No such request.','filename="/home/private/secret.mp3"\nartist="A"',
                     'title="bad\\escape"','initial_uri="title=secret"'):
            self.assertEqual(radio.queue_title(text),'')

    def test_quoted_unicode_controls_and_byte_bound(self):
        value='A "quote" \\ #{1+2}\n\x03\u202e東京🪄'
        title=radio.queue_title('title='+json.dumps(value,ensure_ascii=False))
        self.assertIn('A "quote" \\ #{1+2}',title)
        self.assertNotIn('\n',title);self.assertNotIn('\x03',title);self.assertNotIn('\u202e',title)
        self.assertLessEqual(len(radio.queue_title('title='+json.dumps('🪄'*500)).encode()),240)

    def test_admin_overflow_reads_first_six_and_keeps_total(self):
        b=radio.Backend({'queue_id':'q'})
        ids=' '.join(str(n) for n in range(10))
        with patch.object(b,'command',side_effect=[ids]+['title="x"']*6+[ids]) as command:
            result=b.queue_view()
        self.assertEqual((result['total'],len(result['waiting']),command.call_count),(10,6,8))

    def test_empty_queue_is_an_actual_player_observation(self):
        b=radio.Backend({'queue_id':'q'})
        with patch.object(b,'command',return_value='') as command:
            self.assertEqual(b.queue_view(),{'waiting':[],'total':0})
            self.assertEqual(command.call_count,2)

    def test_expired_deadline_never_opens_a_socket(self):
        b=radio.Backend({'liquidsoap_port':1235})
        with patch('radio_service.socket.create_connection') as connect:
            with self.assertRaises(radio.RadioError):b.command('q.queue',deadline=0)
            connect.assert_not_called()


class SharedQueue(unittest.TestCase):
    setUp, tearDown, body, api = Contract.setUp, Contract.tearDown, Contract.body, Contract.api
    def queue_backend(self, **values):
        result=dict(waiting=[{'title':'Artist — Track'}],total=1)
        result.update(values)
        return patch.object(self.backend,'queue_view',return_value=result,create=True)

    def test_queue_shared_but_jobs_stay_private_and_ledger_unchanged(self):
        self.s.submit('dev',self.body()); self.s.submit('nbot',self.body(2,query='https://youtu.be/12345678901'))
        self.s.update(self.body(2)['id'],state='submitting')
        before=list(self.s.db.iterdump())
        with self.queue_backend() as backend:
            a=self.api('GET','/v1/queue')
            b=self.api('GET','/v1/queue',secret='b'*64)
            self.assertEqual(a,b);self.assertEqual(backend.call_count,1)
        self.assertEqual((a[1]['preparing'],a[1]['transferring']),(1,1))
        self.assertEqual(set(a[1]),{'protocol','waiting','total','preparing','transferring'})
        self.assertEqual(list(self.s.db.iterdump()),before)
        self.assertEqual(self.backend.events,[])
        self.assertEqual(self.api('GET','/v1/requests/'+self.body()['id'],secret='b'*64)[0],404)

    def test_untrusted_method_token_or_query_never_reaches_player(self):
        with self.queue_backend() as backend:
            self.assertEqual(self.api('GET','/v1/queue',secret='c'*64)[0],401)
            for method in ('POST','DELETE','PUT','PATCH','HEAD'):
                self.assertEqual(self.api(method,'/v1/queue')[0],404)
            self.assertEqual(self.api('GET','/v1/queue',QUERY_STRING='command=q.skip')[0],400)
            backend.assert_not_called()

    def test_failed_read_is_not_reported_as_empty_and_is_briefly_cached(self):
        with patch.object(self.backend,'queue_view',side_effect=OSError,create=True) as backend:
            self.assertEqual(self.api('GET','/v1/queue'),(503,{'error':'queue_unavailable'}))
            self.assertEqual(self.api('GET','/v1/queue')[0],503)
            self.assertEqual(backend.call_count,1)

    def test_cache_expires_and_reads_never_hold_the_ledger_lock(self):
        def read():
            acquired=[]
            def other():
                with self.s.lock:acquired.append(True)
            worker=threading.Thread(target=other);worker.start();worker.join(timeout=.5)
            self.assertEqual(acquired,[True])
            return dict(waiting=[],total=0)
        with patch.object(self.backend,'queue_view',side_effect=read,create=True) as backend:
            self.api('GET','/v1/queue');self.s.queue_cache_until=0;self.api('GET','/v1/queue')
            self.assertEqual(backend.call_count,2)

    def test_parallel_read_fails_fast_without_second_player_connection(self):
        with self.queue_backend() as backend, self.s.queue_lock:
            self.assertEqual(self.api('GET','/v1/queue'),(503,{'error':'queue_view_busy'}))
            backend.assert_not_called()

    def test_six_unicode_titles_fit_existing_4096_byte_client_limit(self):
        with self.queue_backend(waiting=[{'title':'🪄'*60}]*6,total=6):
            env=dict(REQUEST_METHOD='GET',PATH_INFO='/v1/queue',HTTP_AUTHORIZATION='Bearer '+self.secret)
            headers=[]
            data=b''.join(self.s(env,lambda status,h:headers.extend(h)))
        self.assertLess(len(data),4096)
        self.assertEqual(len(json.loads(data)['waiting']),6)
        self.assertIn(('Cache-Control','no-store'),headers)


if __name__=='__main__':
    unittest.main(verbosity=1)
