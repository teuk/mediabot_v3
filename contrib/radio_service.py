#!/usr/bin/env python3
"""MB734: one catalogue and request budget, local WSGI API behind optional TLS.

No IRC, shell or user-supplied filesystem paths. Next-track requests are
authorized by Administrator+ checks in each authenticated bot instance.
Run one process. SQLite records uncertainty BEFORE an external queue mutation.
"""
import argparse
import contextlib
import difflib
import fcntl
import hashlib
import hmac
import json
import logging
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time
import unicodedata
from urllib.parse import parse_qs, urlsplit

LOG = logging.getLogger('mediabot-radio')
FINAL = ('queued', 'failed', 'uncertain')
ACTIVE = ('pending', 'working', 'submitting')
STOP = threading.Event()
DOWNLOAD_PAUSES = {'youtube_auth_required': 300, 'youtube_rate_limited': 900}


class RadioError(Exception):
    def __init__(self, code, status=400, retry_after=None):
        self.code, self.status = code, status
        self.retry_after = retry_after
        super().__init__(code)


def require(value, code='invalid_request', status=400, retry_after=None):
    if not value:
        raise RadioError(code, status, retry_after)


def clean(value, limit=255):
    return re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', str(value))[:limit].strip()


def metadata_labels(track, fallback=''):
    """Remove a literal repeated artist prefix, preserving recording/version text."""
    artist = unicodedata.normalize('NFC', clean(track.get('artist') or ''))
    title = unicodedata.normalize('NFC', clean(track.get('title') or fallback))
    if artist:
        prefix = re.compile(r'^' + re.escape(artist) + r'(?:\s+[-–—|]\s+|\s*:\s+)(.+)$', re.IGNORECASE)
        while True:
            match = prefix.match(title)
            if not match or not match[1].strip():
                break
            title = match[1].strip()
    return artist, title


def liquidsoap_string(value):
    """Quote literal UTF-8 for Liquidsoap, including its #{...} preprocessor."""
    require(isinstance(value, str) and not re.search(r'[\ud800-\udfff]', value), 'unsafe_metadata')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('#', '\\x23') + '"'


def track_uri(path, track):
    """Bind catalogue metadata to this request, including older untagged MP3s."""
    artist, title = metadata_labels(track, path.stem)
    return ('annotate:artist=' + liquidsoap_string(artist)
            + ',title=' + liquidsoap_string(title) + ':' + str(path))


def queue_title(metadata):
    """Expose music labels only, never filename, initial_uri or private job fields."""
    labels = {}
    for line in metadata.splitlines():
        match = re.fullmatch(r'(artist|title)=(".*")', line)
        if not match:
            continue
        try:
            value = json.loads(match[2])
        except ValueError:
            continue
        if isinstance(value, str):
            value = ''.join(' ' if unicodedata.category(c).startswith('C') else c for c in value)
            labels[match[1]] = ' '.join(value.split())
    artist, title = metadata_labels(labels)
    if not title:
        return ''  # Do not derive a missing title from a private filesystem path.
    value = artist + ' — ' + title if artist else title
    return value.encode('utf-8')[:240].decode('utf-8', errors='ignore')


def youtube_id(url):
    require(isinstance(url, str) and len(url) <= 512)
    require(not re.search(r'[\x00-\x20\x7f]', url), 'youtube_url_required')
    u = urlsplit(url)
    require(u.scheme == 'https' and not u.username and not u.password
            and u.port is None and not u.fragment, 'youtube_url_required')
    args = parse_qs(u.query, keep_blank_values=True)
    require('list' not in args, 'no_playlists')
    if u.hostname in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com'):
        if u.path == '/watch':
            require(len(args.get('v', [])) == 1, 'youtube_url_required')
            value = args['v'][0]
        else:
            require(u.path.startswith('/shorts/'), 'youtube_url_required')
            value = u.path[len('/shorts/'):]
    elif u.hostname == 'youtu.be':
        value = u.path[1:]
    else:
        raise RadioError('youtube_url_required')
    require(re.fullmatch(r'[A-Za-z0-9_-]{11}', value), 'youtube_url_required')
    return value


def play_input(query):
    """Keep explicit links strict; plain words become a bounded YouTube search."""
    require(isinstance(query, str) and 1 <= len(query) <= 255
            and not any(unicodedata.category(c).startswith('C') for c in query), 'invalid_request')
    if query.startswith('https://'):
        return youtube_id(query)
    # Do not reinterpret a rejected URI, downloader prefix, option or local path
    # as a different source. Search words are never passed as a standalone URL.
    require(not re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', query)
            and not query.startswith(('/', '\\', '~', '-', './', '../'))
            and not re.search(r'(?i)(?:https?://|www\.|youtu(?:be\.com|\.be)/)', query),
            'youtube_url_required')
    return ''


def search_words(value):
    value = unicodedata.normalize('NFKD', clean(value, 512)).casefold()
    return re.findall(r'[^\W_]+', ''.join(c for c in value if not unicodedata.combining(c)))


def music_score(entry, query):
    """Conservative text selection, not a claim to recognize audio quality.

    Do not let an unsolicited cover, lesson or speed edit win merely because
    YouTube placed it first. Explicit versions remain legitimate requests.
    Missing titles fail closed; view counts are deliberately not a gate.
    """
    title = entry.get('title')
    if not isinstance(title, str) or not title.strip():
        return None
    title_words, query_words = search_words(title), search_words(query)
    text, wanted = ' '.join(title_words), ' '.join(query_words)
    versions = (
        r'\b(?:cover|karaoke|instrumental|remix|mashup|parody|parodie)\b',
        r'\b(?:reaction|reacts|reacting|tutorial|lesson|how to play|tutoriel|cours)\b',
        r'\b(?:slowed|sped up|speed up|nightcore|8d audio|bass boosted)\b',
        r'\b(?:ai generated|ai cover|a i cover|reupload|re uploaded)\b',
        r'\b(?:loop|looped|extended version|compilation|full album)\b',
    )
    for pattern in versions:
        matches = re.findall(pattern, text)
        if any(value not in wanted for value in matches):
            return None
    ignore = {'the', 'a', 'an', 'and', 'of', 'de', 'la', 'le', 'les', 'official', 'video', 'audio'}
    terms = set(query_words) - ignore
    candidates = set(title_words + search_words(entry.get('channel') or entry.get('uploader') or ''))
    if not terms:
        return None
    # Permit one ordinary spelling error (Mickael/Michael), not unrelated hits.
    matched = sum(term in candidates or (len(term) >= 5 and any(
        len(word) >= 5 and difflib.SequenceMatcher(None, term, word).ratio() >= .8
        for word in candidates)) for term in terms)
    if matched / len(terms) < .8:
        return None
    score = matched / len(terms) * 100
    if re.search(r'\bofficial (?:music )?(?:video|audio)\b', text):
        score += 8
    channel = ' '.join(search_words(entry.get('channel') or entry.get('uploader') or ''))
    if channel.endswith(' topic') or channel.endswith('vevo'):
        score += 6
    return score


def search_video(result, maximum, query='', allowed=None):
    """Rank at most five relevant music candidates; never search indefinitely."""
    require(isinstance(result, dict) and result.get('_type') == 'playlist'
            and isinstance(result.get('entries'), list)
            and len(result['entries']) <= 5, 'youtube_search_failed', 503)
    choices = []
    for entry in result['entries']:
        if not isinstance(entry, dict) or entry.get('ie_key') != 'Youtube':
            continue
        video, duration = entry.get('id'), entry.get('duration')
        if (not isinstance(video, str) or not re.fullmatch(r'[A-Za-z0-9_-]{11}', video)
                or type(duration) not in (int, float) or not math.isfinite(duration)
                or not 0 < duration <= maximum or entry.get('is_live')
                or entry.get('live_status') in ('is_live', 'is_upcoming', 'post_live')):
            continue
        if allowed and not allowed(video):
            continue
        score = music_score(entry, query) if query else 0
        if score is not None:
            choices.append((score, video))
    if choices:
        # Stable sort preserves YouTube relevance between equal scores.
        return max(choices, key=lambda value: value[0])[1]
    raise RadioError('no_youtube_match', 404)


def bounded_file(path, limit, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        s = os.fstat(stream.fileno())
        require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_size <= limit,
                'unsafe_metadata')
        if private:
            require(s.st_uid == os.getuid() and not s.st_mode & 0o077, 'private_file_required')
        data = stream.read(limit + 1)
        require(len(data) <= limit, 'unsafe_metadata')
        return data


def private_json(path):
    return json.loads(bounded_file(path, 32768, private=True))


def download_error(stderr):
    """Classify bounded stderr without retaining or returning its contents."""
    text = stderr.lower()
    if any(s in text for s in (b'cookies are no longer valid', b'sign in to confirm',
                              b'cookies have expired')):
        return 'youtube_auth_required'
    if any(s in text for s in (b'http error 429', b'too many requests', b'rate limit')):
        return 'youtube_rate_limited'
    if any(s in text for s in (b'private video', b'video unavailable', b'video has been removed',
                              b'not available in your country')):
        return 'youtube_unavailable'
    if b'did not get any data blocks' in text:
        return 'youtube_no_data'
    return 'download_failed'


def run(args, data=None, timeout=20, directory=None, error_classifier=None):
    """Bound output, subprocess lifetime and downloaded scratch space."""
    env = dict(os.environ)
    for key in ('PYTHONPATH', 'PERL5OPT', 'PERL5LIB'):
        env.pop(key, None)
    with subprocess.Popen(args, stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, env=env) as proc:
        if data is not None:
            proc.stdin.write(json.dumps(data).encode())
            proc.stdin.close()
        sel = selectors.DefaultSelector()
        sel.register(proc.stdout, selectors.EVENT_READ, True)
        sel.register(proc.stderr, selectors.EVENT_READ, False)
        output, errors, total = bytearray(), bytearray(), 0
        deadline = time.monotonic() + timeout
        try:
            while sel.get_map():
                require(not STOP.is_set(), 'service_stopping', 503)
                require(time.monotonic() < deadline, 'operation_timeout', 503)
                if directory:
                    size = sum(p.lstat().st_size for p in Path(directory).rglob('*') if p.is_file())
                    require(size <= 128 * 1024 * 1024, 'download_too_large')
                for key, _ in sel.select(0.2):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        sel.unregister(key.fileobj)
                        continue
                    total += len(chunk)
                    require(total <= 1024 * 1024, 'operation_output_limit')
                    if key.data:
                        output.extend(chunk)
                    elif error_classifier:
                        errors.extend(chunk)
            require(proc.wait(timeout=2) == 0,
                    error_classifier(bytes(errors)) if error_classifier else 'operation_failed', 503)
            return bytes(output)
        finally:
            sel.close()
            # The leader may have exited while a descendant still owns a pipe.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
            if proc.poll() is None:
                proc.wait(timeout=5)


class Backend:
    def __init__(self, config):
        self.c = config
        self.download_guard = lambda: None
        self.track_guard = lambda track: None

    def video_allowed(self, video):
        try:
            self.track_guard({'id_youtube': video})
            return True
        except RadioError as error:
            if error.code != 'track_removed':
                raise
            return False

    def remaining(self, deadline, maximum):
        require(not STOP.is_set(), 'service_stopping', 503)
        remaining = deadline - time.monotonic()
        require(remaining > 0, 'catalogue_scan_timeout', 503)
        return min(maximum, remaining)

    def youtube_session(self, directory):
        """The configured cookie file is immutable; yt-dlp receives a private copy."""
        args = []
        if self.c.get('cookies'):
            cookies = Path(directory) / 'cookies.txt'
            try:
                contents = bounded_file(self.c['cookies'], 4 * 1024 * 1024, private=True)
            except (OSError, RadioError):
                raise RadioError('cookies_unavailable', 503) from None
            with cookies.open('xb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(contents)
            args += ['--cookies', str(cookies)]
        if self.c.get('remote_components'):
            args += ['--remote-components', self.c['remote_components']]
        if self.c.get('js_runtime'):
            args += ['--js-runtimes', self.c['js_runtime']]
        return args

    def search(self, query):
        require(play_input(query) == '', 'invalid_request')
        self.download_guard()
        with tempfile.TemporaryDirectory(prefix='.radio-search-', dir=self.c['incoming']) as tmp:
            args = [self.c['yt_dlp'], '--ignore-config', '--no-plugin-dirs',
                    '--flat-playlist', '--skip-download', '--dump-single-json',
                    '--no-progress', '--quiet', '--no-warnings', '--no-mark-watched',
                    '--no-cache-dir', '--use-extractors', 'youtube:search',
                    '--playlist-end', '5', '--socket-timeout', '10', '--retries', '1',
                    '--extractor-retries', '1']
            args += self.youtube_session(tmp)
            args += ['--', 'ytsearch5:' + query]
            raw = run(args, timeout=30, directory=tmp, error_classifier=download_error)
            try:
                result = json.loads(raw)
            except (ValueError, UnicodeError):
                raise RadioError('youtube_search_failed', 503) from None
            return search_video(result, self.c.get('max_duration', 900), query, self.video_allowed)

    def catalogue(self, action, **values):
        result = json.loads(run(['/usr/bin/perl', str(Path(__file__).with_name('radio_catalogue.pl')),
                                 self.c['bot_config']], dict(action=action, **values)))
        require(result.get('ok'), result.get('code', 'catalogue_failed'), 503)
        return result

    def audio(self, path, timeout=20):
        path = Path(path)
        require(path.is_absolute() and str(path) == str(path.resolve()), 'unreadable_track')
        roots = [Path(v).resolve() for v in self.c['music_roots']]
        require(any(path.is_relative_to(root) for root in roots), 'unreadable_track')
        s = path.lstat()
        require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and 0 < s.st_size <= 32 * 1024 * 1024,
                'unreadable_track')
        require(not any(x in str(path) for x in ('\r', '\n', '\x00')), 'unreadable_track')
        probe = json.loads(run(['/usr/bin/ffprobe', '-v', 'error', '-protocol_whitelist', 'file',
                                '-f', 'mp3', '-show_entries',
                                'format=duration:stream=codec_name,codec_type', '-of', 'json', str(path)],
                               timeout=timeout))
        duration = float(probe['format']['duration'])
        require(math.isfinite(duration) and 0 < duration <= self.c.get('max_duration', 900), 'track_too_long')
        require(any(s.get('codec_type') == 'audio' and s.get('codec_name') == 'mp3'
                    for s in probe.get('streams', [])), 'mp3_required')
        return path

    def resolve(self, job):
        deadline = time.monotonic() + 30
        if job['action'] == 'rplay':
            rows = self.catalogue('search', query=job['query'])['tracks']
        else:
            rows = self.catalogue('youtube', youtube=job['video'])['tracks']
        blocked = 0
        for track in rows:
            timeout = self.remaining(deadline, 5)
            try:
                self.track_guard(track)
                track['path'] = str(self.audio(Path(track['folder']) / track['filename'], timeout=timeout))
                path = Path(track['path'])
                # New downloads carry a content fingerprint. Legacy catalogue
                # files remain supported without changing their metadata.
                if path.parent == Path(self.c.get('incoming', '')):
                    video = path.stem
                    if re.fullmatch(r'[A-Za-z0-9_-]{11}', video):
                        sidecar = path.with_suffix('.radio.json')
                        if sidecar.exists() or sidecar.is_symlink():
                            self.cached_metadata(sidecar, path, video)
                return track
            except (OSError, ValueError, KeyError, RadioError) as error:
                if STOP.is_set():
                    raise RadioError('service_stopping', 503)
                reason = error.code if isinstance(error, RadioError) else type(error).__name__
                blocked += reason == 'track_removed'
                LOG.warning('catalogue_skip mp3=%s reason=%s', track.get('id_mp3', '?'), reason)
                continue
        if rows and blocked == len(rows):
            raise RadioError('track_removed', 409)
        if rows and job['action'] == 'rplay':
            raise RadioError('catalogue_tracks_unavailable', 422)
        require(job['action'] == 'play', 'no_matching_track', 404)
        return self.download(job['video'])

    def cached_metadata(self, metadata, audio, video):
        meta = json.loads(bounded_file(metadata, 8192))
        require(isinstance(meta, dict) and meta.get('id') == video, 'video_identity_mismatch')
        require(all(isinstance(meta.get(k), str) and len(meta[k]) <= 255 for k in ('artist', 'title')),
                'unsafe_metadata')
        if 'sha256' in meta or 'size' in meta:
            require(type(meta.get('size')) is int and isinstance(meta.get('sha256'), str)
                    and re.fullmatch(r'[a-f0-9]{64}', meta['sha256']), 'unsafe_metadata')
            content = bounded_file(audio, 32 * 1024 * 1024)
            require(len(content) == meta['size'] and hashlib.sha256(content).hexdigest() == meta['sha256'],
                    'cached_audio_changed')
        return meta

    def download(self, video):
        require(re.fullmatch(r'[A-Za-z0-9_-]{11}', video), 'youtube_url_required')
        self.track_guard({'id_youtube': video})
        incoming = Path(self.c['incoming'])
        final = incoming / (video + '.mp3')
        meta = None
        if final.exists() or final.is_symlink():
            # A prior DB failure/restart may have left a valid final file.
            self.audio(final)
            metadata = incoming / (video + '.radio.json')
            require(metadata.is_file() and not metadata.is_symlink(), 'cached_metadata_missing')
            meta = self.cached_metadata(metadata, final, video)
        else:
            self.download_guard()
            require(shutil.disk_usage(incoming).free >= 512 * 1024 * 1024, 'storage_full', 503)
            with tempfile.TemporaryDirectory(prefix='.radio-', dir=incoming) as tmp:
                out = Path(tmp) / 'audio'
                args = [self.c['yt_dlp'], '--ignore-config', '--no-plugin-dirs', '--no-playlist',
                        '--no-progress', '--quiet', '--no-warnings', '--cache-dir', str(Path(tmp) / 'cache'),
                        '--use-extractors', 'youtube',
                        '--max-filesize', '64M', '--limit-rate', '2M', '--socket-timeout', '15',
                        '--retries', '1', '--fragment-retries', '1', '--write-info-json',
                        '--match-filters', '!is_live & duration > 0 & duration <= ' + str(self.c.get('max_duration', 900)),
                        '-x', '--audio-format', 'mp3', '--audio-quality', '160K',
                        '--output', str(out) + '.%(ext)s']
                args += self.youtube_session(tmp)
                args += ['--', 'https://www.youtube.com/watch?v=' + video]
                run(args, timeout=180, directory=tmp, error_classifier=download_error)
                audio = self.audio(out.with_suffix('.mp3'))
                meta = json.loads(bounded_file(out.with_suffix('.info.json'), 8 * 1024 * 1024))
                require(isinstance(meta, dict) and meta.get('id') == video, 'video_identity_mismatch')
                meta = {'id': video, 'artist': clean(meta.get('artist') or meta.get('uploader') or 'YouTube'),
                        'title': clean(meta.get('track') or meta.get('title') or video)}
                meta['artist'], meta['title'] = metadata_labels(meta)
                content = bounded_file(audio, 32 * 1024 * 1024)
                meta.update(size=len(content), sha256=hashlib.sha256(content).hexdigest())
                # Owner writes, Liquidsoap reads; group inherited from setgid incoming.
                audio.chmod(0o640)
                with audio.open('rb') as stream:
                    os.fsync(stream.fileno())
                metadata = incoming / (video + '.radio.json')
                # A crash before exclusive audio publication may leave only our
                # non-secret metadata. Replace it atomically after identity checks.
                require(not metadata.is_symlink(), 'metadata_collision')
                saved_meta = Path(tmp) / 'metadata.json'
                with saved_meta.open('x') as fh:
                    json.dump(meta, fh)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.replace(saved_meta, metadata)
                os.link(audio, final)  # exclusive publication, never overwrite another track
                audio.unlink()
                fd = os.open(incoming, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
        require(meta.get('id') == video, 'video_identity_mismatch')
        self.audio(final)
        return self.catalogue('register', owner=self.c['catalogue_owner'], youtube=video,
                              folder=str(incoming), filename=final.name,
                              artist=clean(meta['artist']), title=clean(meta['title']))['track']

    def command(self, text, deadline=None):
        """Only the selected local queue, END framing, no retries on mutation."""
        deadline = deadline if deadline is not None else time.monotonic() + 5
        def remaining():
            value = deadline - time.monotonic()
            require(value > 0, 'queue_no_ack', 503)
            return min(5, value)
        with socket.create_connection(('127.0.0.1', self.c['liquidsoap_port']), timeout=remaining()) as sock:
            sock.settimeout(remaining())
            sock.sendall(text.encode() + b'\n')
            data = bytearray()
            while time.monotonic() < deadline:
                sock.settimeout(remaining())
                chunk = sock.recv(4096)
                require(chunk, 'queue_no_ack', 503)
                data.extend(chunk)
                require(len(data) <= 65536, 'queue_bad_ack', 503)
                found = re.search(rb'(?:^|\r?\n)END\r?\n', data)
                if found:
                    return data[:found.start()].decode('utf-8').strip()
            raise RadioError('queue_no_ack', 503)

    def queue_ids(self, deadline):
        value = self.command(self.c['queue_id'] + '.queue', deadline=deadline)
        require(re.fullmatch(r'(?:[0-9]{1,10}(?:\s+[0-9]{1,10})*)?', value) is not None,
                'queue_unavailable', 503)
        result = value.split()
        require(len(result) <= 512 and len(set(result)) == len(result), 'queue_unavailable', 503)
        return result

    def queue_count(self):
        return len(self.queue_ids(time.monotonic() + 1))

    def control_state(self):
        data = json.loads(self.command('mediabot.control_state', deadline=time.monotonic() + 1))
        require(isinstance(data, dict) and data.get('protocol') == 1
                and isinstance(data.get('epoch'), str)
                and re.fullmatch(r'[A-Za-z0-9_.:+-]{1,80}', data['epoch'])
                and type(data.get('serial')) is int and 0 <= data['serial'] < 10**12
                and data.get('origin') in ('live', 'queue', 'playlist', 'none')
                and type(data.get('pending')) is bool
                and data.get('outcome') in ('idle', 'pending', 'sent', 'completed', 'stale', 'unavailable')
                and all(isinstance(data.get(k), str) for k in ('artist', 'title')),
                'next_unavailable', 503)
        data['artist'], data['title'] = metadata_labels(data)
        return data

    def advance(self, state):
        expected = state['epoch'] + ':' + str(state['serial'])
        result = self.command('mediabot.control_next ' + expected, deadline=time.monotonic() + 1)
        require(result in ('accepted', 'stale', 'busy', 'live', 'unavailable'), 'next_no_ack', 503)
        return result

    def placement(self, rid):
        """Position observed after acknowledgement, never a pre-push estimate."""
        require(type(rid) is int and 0 <= rid <= 9999999999, 'queue_bad_ack', 503)
        deadline = time.monotonic() + 2
        before = self.queue_ids(deadline)
        after = self.queue_ids(deadline)
        require(before == after, 'queue_changing', 503)
        if str(rid) in after:
            return 'waiting', after.index(str(rid)) + 1
        # Leaving the waiting list does not prove what Icecast is broadcasting.
        return 'not_waiting', None

    def queue_view(self):
        """Read actual pending RIDs, not historical acknowledgements or on-air guesses."""
        deadline = time.monotonic() + 4
        def ids():
            return self.queue_ids(deadline)
        for _ in range(2):
            before = ids()
            waiting = [{'title': queue_title(self.command('request.metadata ' + rid, deadline=deadline))}
                       for rid in before[:6]]
            if before == ids():
                return {'waiting': waiting, 'total': len(before)}
        raise RadioError('queue_changing', 503)

    def capacity(self):
        value = self.command(self.c['queue_id'] + '.queue')
        require(re.fullmatch(r'[\d\s,\[\]]*', value), 'queue_bad_ack', 503)
        require(len(re.findall(r'\d+', value)) < 6, 'player_queue_full', 429)

    def push(self, track):
        path = self.audio(Path(track.get('path') or Path(track['folder']) / track['filename']))
        value = self.command(self.c['queue_id'] + '.push ' + track_uri(path, track))
        require(re.fullmatch(r'\d+', value), 'queue_bad_ack', 503)
        return int(value)


class Service:
    def __init__(self, config, backend=None, clock=time.time):
        self.c, self.clock = config, clock
        self.backend = backend or Backend(config)
        self.lock = threading.RLock()
        self.queue_lock = threading.Lock()
        self.queue_cache = None
        self.queue_cache_until = 0.
        self.pressure_lock = threading.Lock()
        self.pressure_cache = (0., None)
        self.next_lock = threading.Lock()
        self.catalogue_lock = threading.Lock()
        self.db = sqlite3.connect(config['database'], check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS download_pause (name TEXT PRIMARY KEY, code TEXT NOT NULL, until REAL NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS track_claims (track TEXT PRIMARY KEY, job_id TEXT NOT NULL, updated REAL NOT NULL)')
        # Never prune withdrawals with the seven-day request history. Preserve
        # the original row before any external DELETE, including across crashes.
        self.db.execute('''CREATE TABLE IF NOT EXISTS removed_tracks (
            mp3 TEXT PRIMARY KEY, snapshot TEXT NOT NULL, video TEXT NOT NULL,
            path TEXT NOT NULL, instance TEXT NOT NULL, caller TEXT NOT NULL,
            created REAL NOT NULL, state TEXT NOT NULL)''')
        self.db.execute('''CREATE TABLE IF NOT EXISTS next_receipts (
            id TEXT PRIMARY KEY, instance TEXT NOT NULL, caller TEXT NOT NULL,
            channel TEXT NOT NULL, created REAL NOT NULL, state TEXT NOT NULL,
            code TEXT NOT NULL, title TEXT NOT NULL, origin TEXT NOT NULL)''')
        self.db.execute("UPDATE next_receipts SET state='uncertain',code='next_no_ack' WHERE state='sending'")
        self.db.execute('''CREATE TABLE IF NOT EXISTS queue_receipts (
            job_id TEXT PRIMARY KEY, placement TEXT NOT NULL, position INTEGER)''')
        self.db.execute('CREATE TABLE IF NOT EXISTS job_tracks (job_id TEXT PRIMARY KEY, mp3 TEXT NOT NULL)')
        self.db.execute('''CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, instance TEXT NOT NULL, caller TEXT NOT NULL, channel TEXT NOT NULL,
            action TEXT NOT NULL, query TEXT NOT NULL, video TEXT NOT NULL,
            state TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL,
            code TEXT NOT NULL DEFAULT '', title TEXT NOT NULL DEFAULT '', rid INTEGER)''')
        self.db.execute("UPDATE jobs SET state='uncertain',code='restart_after_push' WHERE state='submitting'")
        self.db.execute("UPDATE jobs SET state='pending' WHERE state='working'")
        self.db.commit()
        self.backend.download_guard = self.download_guard
        self.backend.track_guard = self.track_guard

    def track_guard(self, track):
        video = track.get('id_youtube') or ''
        mp3 = str(track.get('id_mp3') or '')
        path = str(Path(track['folder']) / track['filename']) if track.get('folder') and track.get('filename') else ''
        with self.lock:
            row = self.db.execute('''SELECT 1 FROM removed_tracks WHERE mp3=?
                OR (video<>'' AND video=?) OR (path<>'' AND path=?) LIMIT 1''', (mp3, video, path)).fetchone()
        require(row is None, 'track_removed', 409)

    def remove_track(self, instance, body):
        # Only trusted bot instances can reach this method. Their authenticated
        # Master+ gate is mandatory; a role in JSON never grants authority.
        require(isinstance(body, dict) and set(body) == {'id', 'caller', 'channel', 'mp3'}
                and all(isinstance(v, str) for v in body.values()))
        require(re.fullmatch(r'[a-f0-9]{32}', body['id'])
                and re.fullmatch(r'[a-f0-9]{64}', body['caller'])
                and re.fullmatch(r'#[^\s,\x00-\x1f]{1,99}', body['channel'])
                and re.fullmatch(r'[1-9][0-9]{0,18}', body['mp3']))
        require(self.catalogue_lock.acquire(blocking=False), 'catalogue_busy', 409)
        try:
            with self.lock:
                previous = self.db.execute('SELECT * FROM removed_tracks WHERE mp3=?', (body['mp3'],)).fetchone()
            if previous:
                track = json.loads(previous['snapshot'])
            else:
                track = self.backend.catalogue('get', mp3=body['mp3']).get('track')
                require(isinstance(track, dict) and str(track.get('id_mp3')) == body['mp3'], 'track_not_found', 404)
                require(set(track) == {'id_mp3','id_user','id_youtube','folder','filename','artist','title'}
                        and all(v is None or type(v) in (int, str) for v in track.values()), 'catalogue_failed', 503)
                require(all(len(str(v or '')) <= 255 for v in track.values()), 'catalogue_failed', 503)
                video = track.get('id_youtube') or ''
                path = str(Path(track['folder']) / track['filename'])
                # This durable intent blocks play/cache/rplay immediately. No
                # audio unlink: existing playout and third-party playlists survive.
                with self.lock, self.db:
                    self.db.execute('INSERT INTO removed_tracks VALUES (?,?,?,?,?,?,?,?)',
                        (body['mp3'], json.dumps(track, ensure_ascii=False), video, path,
                         instance, body['caller'], self.clock(), 'pending'))
            if not previous or previous['state'] != 'removed':
                result = self.backend.catalogue('remove', mp3=body['mp3'], expected=track)
                require(result.get('removed') is True, 'catalogue_changed', 409)
                with self.lock, self.db:
                    self.db.execute("UPDATE removed_tracks SET state='removed' WHERE mp3=?", (body['mp3'],))
            artist, title = metadata_labels(track)
            LOG.info('track=%s withdrawn instance=%s', body['mp3'], instance)
            return dict(state='removed', mp3=body['mp3'], title=clean(artist+' — '+title, 180))
        finally:
            self.catalogue_lock.release()

    def download_guard(self):
        with self.lock:
            row = self.db.execute("SELECT * FROM download_pause WHERE name='youtube'").fetchone()
            if row and row['until'] > self.clock():
                raise RadioError('youtube_paused', 503)

    def claim(self, job_id, track):
        # The same central row must not be pushed by rplay while another bot
        # requests it via play. Video identity also covers duplicate DB rows.
        video = track.get('id_youtube', '')
        if isinstance(video, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video):
            key = 'youtube:' + video
        else:
            key = 'path:' + str(track.get('path') or Path(track['folder']) / track['filename'])
        key = hashlib.sha256(key.encode('utf-8')).hexdigest()
        with self.lock, self.db:
            if isinstance(video, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video):
                # Existing pre-hardening play jobs already record video IDs.
                recent = self.db.execute('''SELECT 1 FROM jobs WHERE video=? AND id<>? AND
                    (state IN ('pending','working','submitting') OR
                     (state IN ('queued','uncertain') AND updated>?)) LIMIT 1''',
                    (video, job_id, self.clock() - 600)).fetchone()
                require(recent is None, 'duplicate_track', 409)
            old = self.db.execute('''SELECT c.*,j.state FROM track_claims c
                                    LEFT JOIN jobs j ON j.id=c.job_id WHERE c.track=?''', (key,)).fetchone()
            if old and old['job_id'] != job_id:
                require(old['state'] not in ACTIVE and old['updated'] <= self.clock() - 600,
                        'duplicate_track', 409)
            self.db.execute('INSERT OR REPLACE INTO track_claims VALUES (?,?,?)', (key, job_id, self.clock()))

    def view(self, row):
        result = {k: row[k] for k in ('id', 'state', 'code', 'title', 'rid')}
        if row['state'] == 'queued':
            receipt = self.db.execute('SELECT placement,position FROM queue_receipts WHERE job_id=?', (row['id'],)).fetchone()
            result.update(dict(receipt) if receipt else dict(placement='unknown', position=None))
            track = self.db.execute('SELECT mp3 FROM job_tracks WHERE job_id=?', (row['id'],)).fetchone()
            if track:
                result['mp3'] = track['mp3']
        return result

    def submit(self, instance, body):
        require(isinstance(body, dict) and set(body) == {'id', 'caller', 'channel', 'action', 'query'})
        require(all(isinstance(v, str) for v in body.values()))
        require(re.fullmatch(r'[a-f0-9]{32}', body['id']))
        require(re.fullmatch(r'[a-f0-9]{64}', body['caller']))
        require(re.fullmatch(r'#[^\s,\x00-\x1f]{1,99}', body['channel']))
        require(body['action'] in ('play', 'rplay'))
        query = body['query'].strip()
        require(1 <= len(query) <= 255 and clean(query) == query)
        video = play_input(query) if body['action'] == 'play' else ''
        # Idempotent retries never need another player query. Recheck under
        # the transaction below after I/O, as another HTTP thread may insert.
        with self.lock:
            old = self.db.execute('SELECT * FROM jobs WHERE id=?', (body['id'],)).fetchone()
            if old:
                require(old['instance'] == instance and all(old[k] == body[k] for k in ('caller', 'channel', 'action'))
                        and old['query'] == query, 'request_id_conflict', 409)
                return self.view(old)
        if video:
            self.track_guard({'id_youtube': video})
        waiting = self.waiting_pressure()
        with self.lock, self.db:
            now = self.clock()
            old = self.db.execute('SELECT * FROM jobs WHERE id=?', (body['id'],)).fetchone()
            if old:
                require(old['instance'] == instance and all(old[k] == body[k] for k in ('caller', 'channel', 'action'))
                        and old['query'] == query, 'request_id_conflict', 409)
                return self.view(old)
            self.db.execute("DELETE FROM jobs WHERE state IN ('queued','failed','uncertain') AND updated < ?", (now - 604800,))
            self.db.execute('DELETE FROM queue_receipts WHERE job_id NOT IN (SELECT id FROM jobs)')
            self.db.execute('DELETE FROM job_tracks WHERE job_id NOT IN (SELECT id FROM jobs)')
            rows = self.db.execute('SELECT * FROM jobs WHERE updated > ? OR created > ? OR state IN (?,?,?)',
                                   (now - 600, now - 600, *ACTIVE)).fetchall()
            self.db.execute('''DELETE FROM track_claims WHERE updated < ? AND job_id NOT IN
                               (SELECT id FROM jobs WHERE state IN ('pending','working','submitting'))''',
                            (now - 604800,))
            require(sum(r['state'] in ACTIVE for r in rows) < 6, 'service_queue_full', 429)
            active = sum(r['state'] in ACTIVE for r in rows)
            # A preparing download reserves capacity even before it reaches
            # Liquidsoap. A failed read retains the old conservative budget.
            pressure = min(5, waiting + active) if waiting is not None else None
            caller_delay = (5, 15, 30, 45, 60, 90)[pressure] if pressure is not None else 120
            channel_delay = (5, 5, 10, 15, 20, 30)[pressure] if pressure is not None else 15
            caller_wait = channel_wait = 0
            for row in rows:
                no_match = (row['state'] == 'failed' and
                            ((row['action'] == 'rplay' and row['code'] == 'no_matching_track')
                             or (row['action'] == 'play' and row['code'] == 'no_youtube_match')))
                if row['instance'] == instance and row['caller'] == body['caller']:
                    if row['state'] in ACTIVE:
                        raise RadioError('request_pending', 429, 5)
                    delay = 5 if no_match else caller_delay if row['state'] == 'queued' else 120
                    wait = math.ceil(delay - (now - row['created']))
                    caller_wait = max(caller_wait, wait)
                if row['instance'] == instance and row['channel'] == body['channel']:
                    wait = math.ceil((5 if no_match else channel_delay) - (now - row['created']))
                    channel_wait = max(channel_wait, wait)
                if video and row['video'] == video:
                    require(row['state'] not in ACTIVE + ('queued', 'uncertain'), 'duplicate_video', 409)
            if max(caller_wait, channel_wait) > 0:
                code = 'caller_cooldown' if caller_wait >= channel_wait else 'channel_cooldown'
                raise RadioError(code, 429, max(caller_wait, channel_wait))
            self.db.execute('''INSERT INTO jobs (id,instance,caller,channel,action,query,video,state,created,updated)
                               VALUES (?,?,?,?,?,?,?,'pending',?,?)''',
                            (body['id'], instance, body['caller'], body['channel'], body['action'], query, video, now, now))
            return self.view(self.db.execute('SELECT * FROM jobs WHERE id=?', (body['id'],)).fetchone())

    def waiting_pressure(self):
        """Bounded shared player read, outside the durable ledger lock."""
        if not self.pressure_lock.acquire(blocking=False):
            return None
        try:
            until, count = self.pressure_cache
            if time.monotonic() >= until:
                try:
                    count = self.backend.queue_count()
                    require(type(count) is int and 0 <= count <= 512, 'queue_unavailable')
                except Exception:
                    count = None
                self.pressure_cache = (time.monotonic() + 2, count)
            return count
        finally:
            self.pressure_lock.release()

    def advance(self, instance, body):
        # The authenticated Mediabot instance authorizes Administrator+ before
        # sending this operation. No caller-supplied role grants privileges.
        require(isinstance(body, dict) and set(body) == {'id', 'caller', 'channel'}
                and all(isinstance(v, str) for v in body.values()))
        require(re.fullmatch(r'[a-f0-9]{32}', body['id'])
                and re.fullmatch(r'[a-f0-9]{64}', body['caller'])
                and re.fullmatch(r'#[^\s,\x00-\x1f]{1,99}', body['channel']))
        def old_receipt():
            row = self.db.execute('SELECT * FROM next_receipts WHERE id=?', (body['id'],)).fetchone()
            if row:
                require(row['instance'] == instance and all(row[k] == body[k] for k in ('caller', 'channel')),
                        'request_id_conflict', 409)
                return {k: row[k] for k in ('state', 'code', 'title', 'origin')}
        with self.lock:
            old = old_receipt()
            if old is not None:
                return old
        require(self.next_lock.acquire(blocking=False), 'next_busy', 429, 15)
        try:
            with self.lock:
                old = old_receipt()
                if old is not None:
                    return old
                latest = self.db.execute('SELECT max(created) FROM next_receipts').fetchone()[0]
                if latest is not None:
                    delay = math.ceil(15 - (self.clock() - latest))
                    require(delay <= 0, 'next_busy', 429, max(1, delay))
            try:
                before = self.backend.control_state()
            except Exception:
                raise RadioError('next_unavailable', 503) from None
            require(before['origin'] != 'live', 'next_live', 409)
            require(before['origin'] != 'none' and before['serial'] > 0, 'next_unavailable', 503)
            require(not before['pending'], 'next_busy', 429, 15)
            # Persist before any possible mutation: retries and restarts never
            # send a second skip, even when an acknowledgement is lost.
            with self.lock, self.db:
                self.db.execute('DELETE FROM next_receipts WHERE created < ?', (self.clock() - 604800,))
                self.db.execute('INSERT INTO next_receipts VALUES (?,?,?,?,?,?,?,?,?)',
                    (body['id'], instance, body['caller'], body['channel'], self.clock(),
                     'sending', '', '', 'none'))
            state, code, title, origin = 'uncertain', 'next_no_ack', '', 'none'
            try:
                ack = self.backend.advance(before)
                if ack != 'accepted':
                    state, code = 'failed', {'live': 'next_live', 'stale': 'next_changed',
                        'busy': 'next_busy', 'unavailable': 'next_unavailable'}[ack]
                else:
                    deadline = time.monotonic() + 4
                    while time.monotonic() < deadline and not STOP.is_set():
                        after = self.backend.control_state()
                        if after['epoch'] != before['epoch']:
                            break
                        if after['outcome'] == 'completed' and after['serial'] > before['serial']:
                            title = clean(after['artist'] + ' — ' + after['title'], 180) if after['artist'] else clean(after['title'], 180)
                            state, code, origin = 'completed', '', after['origin']
                            break
                        if after['outcome'] in ('stale', 'unavailable'):
                            state, code = 'failed', 'next_changed'
                            break
                        time.sleep(.1)
            except Exception:
                LOG.warning('next=%s confirmation=unavailable', body['id'])
            with self.lock, self.db:
                self.db.execute('UPDATE next_receipts SET state=?,code=?,title=?,origin=? WHERE id=?',
                    (state, code, title, origin, body['id']))
            self.queue_cache_until = 0.
            self.pressure_cache = (0., None)
            return dict(state=state, code=code, title=title, origin=origin)
        finally:
            self.next_lock.release()

    def status(self, instance, job_id):
        with self.lock:
            row = self.db.execute('SELECT * FROM jobs WHERE id=? AND instance=?', (job_id, instance)).fetchone()
            require(row is not None, 'not_found', 404)
            return self.view(row)

    def queue_status(self):
        # One bounded read at a time for all clients. The ledger lock is never
        # held during player I/O, so observing cannot block durable acceptance.
        require(self.queue_lock.acquire(blocking=False), 'queue_view_busy', 503)
        try:
            now = time.monotonic()
            if now >= self.queue_cache_until:
                try:
                    self.queue_cache = self.backend.queue_view()
                except Exception:
                    self.queue_cache = {'error': 'queue_unavailable'}
                self.queue_cache_until = time.monotonic() + 2
            require('error' not in self.queue_cache, 'queue_unavailable', 503)
            with self.lock:
                counts = dict(self.db.execute("SELECT state,count(*) FROM jobs WHERE state IN ('pending','working','submitting') GROUP BY state"))
            return dict(self.queue_cache, protocol=1,
                        preparing=counts.get('pending', 0) + counts.get('working', 0),
                        transferring=counts.get('submitting', 0))
        finally:
            self.queue_lock.release()

    def update(self, job_id, **values):
        with self.lock, self.db:
            values['updated'] = self.clock()
            self.db.execute('UPDATE jobs SET ' + ','.join(k + '=?' for k in values) + ' WHERE id=?',
                            (*values.values(), job_id))

    def work_once(self):
        with self.lock:
            row = self.db.execute("SELECT * FROM jobs WHERE state='pending' ORDER BY created,id LIMIT 1").fetchone()
            if row is None:
                return False
            job = dict(row)
            self.update(job['id'], state='working')
        submitting = False
        acquired = False
        try:
            self.backend.capacity()
            if job['action'] == 'play' and not job['video']:
                video = self.backend.search(job['query'])
                require(isinstance(video, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video),
                        'youtube_search_failed', 503)
                # Pin BEFORE audio/network/catalogue mutation. A recovered job
                # will use the same video, even if search results have changed.
                self.update(job['id'], video=video)
                job['video'] = video
            if job['action'] == 'play':
                with self.lock:
                    duplicate = self.db.execute('''SELECT id FROM jobs WHERE id<>? AND video=?
                        AND (state IN ('working','submitting','queued','uncertain')
                             AND (state IN ('working','submitting') OR updated>?)) LIMIT 1''',
                        (job['id'], job['video'], self.clock() - 600)).fetchone()
                    require(duplicate is None, 'duplicate_video', 409)
            self.catalogue_lock.acquire()
            acquired = True
            track = self.backend.resolve(job)  # mandatory catalogue success before push
            self.track_guard(track)
            # Apply the same labels to older catalogue/cache entries without
            # rewriting their files, sidecars or database ownership.
            track = dict(track)
            track['artist'], track['title'] = metadata_labels(track)
            self.backend.capacity()
            require(not STOP.is_set(), 'service_stopping', 503)
            self.claim(job['id'], track)
            mp3 = str(track.get('id_mp3') or '')
            if re.fullmatch(r'[1-9][0-9]{0,18}', mp3):
                with self.lock, self.db:
                    self.db.execute('INSERT OR REPLACE INTO job_tracks VALUES (?,?)', (job['id'], mp3))
            self.update(job['id'], state='submitting', title=clean(track['artist'] + ' — ' + track['title'], 180))
            submitting = True
            rid = self.backend.push(track)
            # Optional readback must never turn an acknowledged push into a
            # failure/retry. Keep the observed rank with its original receipt.
            placement, position = 'unknown', None
            try:
                observed, rank = self.backend.placement(rid)
                require((observed == 'waiting' and type(rank) is int and 1 <= rank <= 512)
                        or (observed == 'not_waiting' and rank is None), 'queue_bad_position')
                placement, position = observed, rank
            except Exception:
                LOG.info('job=%s queue_position=unavailable', job['id'])
            with self.lock, self.db:
                self.db.execute('INSERT OR REPLACE INTO queue_receipts VALUES (?,?,?)',
                                (job['id'], placement, position))
                self.db.execute("UPDATE jobs SET state='queued',rid=?,updated=? WHERE id=?",
                                (rid, self.clock(), job['id']))
        except Exception as error:
            code = error.code if isinstance(error, RadioError) else 'operation_failed'
            self.update(job['id'], state='uncertain' if submitting else 'failed', code=code)
            if code in DOWNLOAD_PAUSES:
                with self.lock, self.db:
                    self.db.execute('INSERT OR REPLACE INTO download_pause VALUES (?,?,?)',
                                    ('youtube', code, self.clock() + DOWNLOAD_PAUSES[code]))
        finally:
            if acquired:
                self.catalogue_lock.release()
        with self.lock, self.db:
            if submitting:
                self.db.execute('UPDATE track_claims SET updated=? WHERE job_id=?', (self.clock(), job['id']))
            else:
                self.db.execute('DELETE FROM track_claims WHERE job_id=?', (job['id'],))
        result = self.status(job['instance'], job['id'])
        LOG.info('job=%s instance=%s state=%s code=%s', job['id'], job['instance'], result['state'], result['code'] or 'none')
        return True

    def worker(self):
        while not STOP.is_set():
            if not self.work_once():
                STOP.wait(0.5)

    def __call__(self, env, start):
        try:
            require(not env.get('HTTP_TRANSFER_ENCODING'), 'invalid_framing')
            auth = env.get('HTTP_AUTHORIZATION', '')
            require(auth.startswith('Bearer ') and re.fullmatch(r'[a-f0-9]{64}', auth[7:]), 'unauthorized', 401)
            digest = hashlib.sha256(auth[7:].encode()).hexdigest()
            instance = next((name for name, value in self.c['token_hashes'].items()
                             if hmac.compare_digest(value, digest)), None)
            require(instance is not None, 'unauthorized', 401)
            require(not hasattr(self, 'worker_thread') or self.worker_thread.is_alive(), 'worker_unavailable', 503)
            method, path = env['REQUEST_METHOD'], env.get('PATH_INFO', '')
            require(not env.get('QUERY_STRING'), 'invalid_request')
            if method == 'GET' and path == '/v1/health':
                result, status = {'ok': True, 'protocol': 1}, 200
            elif method == 'GET' and path == '/v1/queue':
                result, status = self.queue_status(), 200
            elif method == 'GET' and re.fullmatch(r'/v1/requests/[a-f0-9]{32}', path):
                result, status = self.status(instance, path.rsplit('/', 1)[1]), 200
            elif method == 'POST' and path in ('/v1/requests', '/v1/next', '/v1/tracks/remove'):
                require(env.get('CONTENT_TYPE', '').split(';')[0] == 'application/json', 'json_required', 415)
                size = env.get('CONTENT_LENGTH', '')
                require(size.isdecimal() and 0 < int(size) <= 4096, 'invalid_length', 413)
                data = env['wsgi.input'].read(int(size))
                require(len(data) == int(size), 'invalid_length')
                operation = {'/v1/requests': self.submit, '/v1/next': self.advance,
                             '/v1/tracks/remove': self.remove_track}[path]
                result = operation(instance, json.loads(data))
                status = 202
            else:
                raise RadioError('not_found', 404)
        except RadioError as error:
            result, status = {'error': error.code}, error.status
            if error.retry_after is not None:
                result['retry_after'] = error.retry_after
        except (ValueError, TypeError, KeyError):
            result, status = {'error': 'invalid_request'}, 400
        except Exception:
            LOG.error('api=internal_error')
            result, status = {'error': 'unavailable'}, 503
        payload = json.dumps(result, ensure_ascii=env.get('PATH_INFO') != '/v1/queue').encode()
        reason = {200: 'OK', 202: 'Accepted', 400: 'Bad Request', 401: 'Unauthorized', 404: 'Not Found',
                  409: 'Conflict', 413: 'Content Too Large', 415: 'Unsupported Media Type',
                  422: 'Unprocessable Content', 429: 'Too Many Requests', 503: 'Service Unavailable'}[status]
        start(str(status) + ' ' + reason, [('Content-Type', 'application/json'), ('Content-Length', str(len(payload))),
                                         ('Cache-Control', 'no-store'), ('X-Content-Type-Options', 'nosniff')])
        return [payload]


def validate_config(c):
    require(c.get('listen_host', '127.0.0.1') == '127.0.0.1', 'loopback_only')
    for key in ('listen_port', 'liquidsoap_port'):
        require(type(c[key]) is int and 1024 <= c[key] <= 65535, 'invalid_port')
    require(c['listen_port'] not in (8000, 15000, c['liquidsoap_port']), 'invalid_port')
    require(re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}', c['queue_id']), 'invalid_queue')
    require(type(c['catalogue_owner']) is int and c['catalogue_owner'] > 0, 'catalogue_owner_required')
    require(type(c.get('max_duration', 900)) is int and 1 <= c.get('max_duration', 900) <= 3600)
    require(1 <= len(c['token_hashes']) <= 32, 'tokens_required')
    require(len(set(c['token_hashes'].values())) == len(c['token_hashes']), 'distinct_tokens_required')
    require(all(re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', k) and re.fullmatch(r'[a-f0-9]{64}', v)
                for k, v in c['token_hashes'].items()), 'invalid_token_identity')
    incoming = Path(c['incoming'])
    require(incoming.is_absolute() and str(incoming) == str(incoming.resolve()) and incoming.is_dir(), 'incoming_required')
    require(any(incoming == Path(r) for r in c['music_roots']), 'incoming_root_required')
    require(incoming.stat().st_mode & 0o2000 and not incoming.stat().st_mode & 0o007, 'shared_group_required')
    require(Path(c['database']).parent.is_dir() and not Path(c['database']).parent.stat().st_mode & 0o077, 'private_state_required')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    c = private_json(args.config)
    validate_config(c)
    # Prevent two worker processes from submitting the same durable request.
    lock = open(c['database'] + '.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    service = Service(c)
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    thread = threading.Thread(target=service.worker, daemon=True)
    service.worker_thread = thread
    thread.start()
    def stopping(*_):
        STOP.set()
        thread.join(timeout=8)
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    from waitress import serve
    serve(service, host='127.0.0.1', port=c['listen_port'], threads=4, connection_limit=32,
          channel_timeout=10, cleanup_interval=5, max_request_header_size=8192,
          max_request_body_size=4096, expose_tracebacks=False, ident='mediabot-radio')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        # Never expose downloaded metadata, configuration or database credentials.
        raise SystemExit('radio service: ' + (error.code if isinstance(error, RadioError) else type(error).__name__))
