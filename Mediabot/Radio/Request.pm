package Mediabot::Radio::Request;

use strict;
use warnings;

use File::Basename qw(basename dirname);
use File::Spec;
use File::Find qw(find);
use IO::Async::Timer::Countdown;
use POSIX qw(WNOHANG);
use DBI;
use JSON::PP qw(decode_json);
use Time::HiRes qw(time);

use Mediabot::Helpers qw(botNotice botPrivmsg logBot);
use Mediabot::Liquidsoap;

=head1 NAME

Mediabot::Radio::Request - Cache/download/push radio requests.

=head1 DESCRIPTION

First implementation of the Mediabot radio request pipeline.

The order is deliberately conservative:

  1. Search the local MP3 table/cache.
  2. If a readable cached file exists, push it to Liquidsoap immediately.
  3. Otherwise start yt-dlp in a child process and poll it without blocking IRC.
  4. On success, insert the MP3 row and push the file to Liquidsoap.
  5. On failure, report a clean error.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        bot => $args{bot},
    };

    return bless $self, $class;
}

sub _conf_value {
    my ($self, $key, $default) = @_;

    my $bot  = $self->{bot};
    my $conf = $bot->{conf};

    return $default unless $conf && $conf->can('get');

    my $v = $conf->get("radio.$key");
    $v = $conf->get($key) unless defined($v) && $v ne '';

    return defined($v) && $v ne '' ? $v : $default;
}

sub _logger {
    my ($self, $level, $msg) = @_;
    my $bot = $self->{bot};
    return unless $bot && $bot->{logger} && $bot->{logger}->can('log');
    $bot->{logger}->log($level, "RadioRequest: $msg");
}

sub _bool_conf_value {
    my ($self, $key, $default) = @_;

    my $v = $self->_conf_value($key, undef);

    return $default unless defined($v) && $v ne '';

    return 1 if $v =~ /^(?:1|yes|true|on|enabled)$/i;
    return 0 if $v =~ /^(?:0|no|false|off|disabled)$/i;

    return $default;
}

sub _liquidsoap_client {
    my ($self) = @_;

    my $host = $self->_conf_value('LIQUIDSOAP_TELNET_HOST', '127.0.0.1');
    my $port = $self->_conf_value('LIQUIDSOAP_TELNET_PORT', 1235);
    my $qid  = $self->_conf_value('LIQUIDSOAP_QUEUE_ID', 'mediabot_queue');

    $port = 1235 unless defined($port) && $port =~ /^\d+$/ && $port > 0;

    return Mediabot::Liquidsoap->new(
        host     => $host,
        port     => int($port),
        queue_id => $qid,
        timeout  => 5,
        logger   => $self->{bot}->{logger},
    );
}

sub _say {
    my ($self, $ctx, $text) = @_;

    my $bot     = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;

    if (defined($channel) && $channel =~ /^#/) {
        botPrivmsg($bot, $channel, $text);
    }
    else {
        botNotice($bot, $nick, $text);
    }
}

sub _escape_like {
    my ($text) = @_;

    my @tokens = grep { length } split(/\s+/, $text // '');
    my @safe = map {
        my $t = $_;
        $t =~ s/!/!!/g;
        $t =~ s/%/!%/g;
        $t =~ s/_/!_/g;
        $t;
    } @tokens;

    return '%' . join('%', @safe) . '%';
}

sub _full_path {
    my ($folder, $filename) = @_;

    return undef unless defined($folder) && defined($filename);
    return undef if $folder eq '' || $filename eq '';

    return File::Spec->catfile($folder, $filename);
}

sub _extract_youtube_id {
    my ($text) = @_;

    return undef unless defined($text) && $text ne '';

    # Common YouTube URL forms:
    #   https://www.youtube.com/watch?v=VIDEOID
    #   https://youtu.be/VIDEOID
    #   https://www.youtube.com/shorts/VIDEOID
    #   plain VIDEOID
    if ($text =~ m{(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})}) {
        return $1;
    }

    if ($text =~ /^([A-Za-z0-9_-]{11})$/) {
        return $1;
    }

    return undef;
}

sub _row_with_readable_path {
    my ($row) = @_;

    return undef unless $row;

    my $path = _full_path($row->{folder}, $row->{filename});
    return undef unless defined($path) && -r $path;

    $row->{path} = $path;
    return $row;
}

sub _find_cached_mp3 {
    my ($self, $query) = @_;

    my $bot = $self->{bot};
    my $dbh = $bot->{dbh};
    return undef unless $dbh;

    # First try the strongest cache key when the request is a YouTube URL/id.
    # This avoids fuzzy title matching when the caller already provides an id.
    if (my $ytid = _extract_youtube_id($query)) {
        my $sql = q{
            SELECT id_mp3, id_youtube, artist, title, folder, filename
            FROM MP3
            WHERE id_youtube = ?
            ORDER BY id_mp3 DESC
            LIMIT 5
        };

        my $sth = $dbh->prepare($sql);
        unless ($sth && $sth->execute($ytid)) {
            $self->_logger(1, "cache lookup by id_youtube failed: $DBI::errstr");
            $sth->finish if $sth;
            return undef;
        }

        while (my $row = $sth->fetchrow_hashref) {
            if (my $ready = _row_with_readable_path($row)) {
                $sth->finish;
                $self->_logger(4, "cache hit by id_youtube=$ytid path=$ready->{path}");
                return $ready;
            }
        }

        $sth->finish;
    }

    my $pattern = _escape_like($query);

    my $sql = q{
        SELECT id_mp3, id_youtube, artist, title, folder, filename
        FROM MP3
        WHERE CONCAT(artist, ' ', title) LIKE ? ESCAPE '!'
        ORDER BY id_mp3 DESC
        LIMIT 20
    };

    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute($pattern)) {
        $self->_logger(1, "cache lookup failed: $DBI::errstr");
        $sth->finish if $sth;
        return undef;
    }

    while (my $row = $sth->fetchrow_hashref) {
        if (my $ready = _row_with_readable_path($row)) {
            $sth->finish;
            $self->_logger(4, "cache hit by title query='$query' path=$ready->{path}");
            return $ready;
        }
    }

    $sth->finish;
    return undef;
}

sub _push_cached {
    my ($self, $ctx, $row) = @_;

    my $path = $row->{path};

    my $liq = $self->_liquidsoap_client;
    my ($ok, $response) = $liq->push($path);

    unless ($ok) {
        $self->_say($ctx, "Radio: cache hit, but Liquidsoap could not queue the MP3: $response");
        return 0;
    }

    my $artist = defined($row->{artist}) && $row->{artist} ne '' ? $row->{artist} : 'Unknown';
    my $title  = defined($row->{title})  && $row->{title}  ne '' ? $row->{title}  : basename($path);

    $self->_say($ctx, "Radio: queued from local cache: $artist - $title");
    return 1;
}

sub play {
    my ($self, %args) = @_;

    my $ctx   = $args{ctx};
    my $query = $args{query} // '';
    my $uid   = $args{id_user};

    $query =~ s/^\s+|\s+$//g;

    unless ($query ne '') {
        botNotice($ctx->bot, $ctx->nick, "Syntax: play <artist/title/search>");
        return;
    }

    if (my $cached = $self->_find_cached_mp3($query)) {
        $self->_push_cached($ctx, $cached);
        logBot($ctx->bot, $ctx->message, $ctx->channel, 'play', 'cache', $query);
        return 1;
    }

    # Safe rollout default: m play can always use the local MP3 cache, but
    # remote downloads must be explicitly enabled per instance. This prevents
    # production bots from becoming accidental public download endpoints.
    unless ($self->_bool_conf_value('RADIO_DOWNLOAD_ENABLED', 0)) {
        $self->_say($ctx, "Radio: not found in local MP3 cache. Downloads are disabled on this instance (RADIO_DOWNLOAD_ENABLED=0).");
        logBot($ctx->bot, $ctx->message, $ctx->channel, 'play', 'cache-miss-download-disabled', $query);
        return;
    }

    return $self->_start_download(%args, query => $query, id_user => $uid);
}

sub _start_download {
    my ($self, %args) = @_;

    my $ctx   = $args{ctx};
    my $query = $args{query};
    my $uid   = $args{id_user} || 0;

    my $bot  = $self->{bot};
    my $loop = $bot->{loop};

    unless ($loop) {
        botNotice($bot, $ctx->nick, "Radio: internal error: async event loop is unavailable, cannot start download.");
        return;
    }

    # First hardening pass:
    # keep one yt-dlp download active per bot instance. This avoids spawning
    # several expensive downloads from repeated IRC commands while the feature
    # is still in controlled rollout.
    $bot->{_radio_request_download} //= {};
    if ($bot->{_radio_request_download}->{active}) {
        my $running_query = $bot->{_radio_request_download}->{query} // 'unknown request';
        $self->_say($ctx, "Radio: another download is already running: $running_query. Use radiodlstatus or radiodlcancel.");
        return;
    }

    my $incoming = $self->_conf_value('YOUTUBEDL_INCOMING', '/tmp');
    my $ytdlp    = $self->_conf_value('YTDLP_PATH', '/usr/bin/yt-dlp');
    my $cookies  = $self->_conf_value('YTDLP_COOKIES_FILE', '');
    my $remote_components = $self->_conf_value('YTDLP_REMOTE_COMPONENTS', '');
    my $timeout  = $self->_conf_value('YTDLP_TIMEOUT', 180);
    $timeout = 180 unless defined($timeout) && $timeout =~ /^\d+$/ && $timeout >= 30;

    unless (-x $ytdlp) {
        botNotice($bot, $ctx->nick, "Radio: yt-dlp is not executable or missing: $ytdlp");
        return;
    }

    unless (-d $incoming && -w $incoming) {
        botNotice($bot, $ctx->nick, "Radio: incoming MP3 directory is missing or not writable: $incoming");
        return;
    }

    my $jobdir = File::Spec->catdir($incoming, '.mediabot_jobs');
    unless (-d $jobdir) {
        mkdir $jobdir, 0775;
    }

    unless (-d $jobdir && -w $jobdir) {
        botNotice($bot, $ctx->nick, "Radio: temporary yt-dlp job directory is missing or not writable: $jobdir");
        return;
    }

    $self->_cleanup_jobdir($jobdir, 3600);

    my $stamp = int(time()) . ".$$." . int(rand(100000));
    my $stdout = File::Spec->catfile($jobdir, "yt-dlp.$stamp.out");
    my $stderr = File::Spec->catfile($jobdir, "yt-dlp.$stamp.err");

    my @cmd = (
        $ytdlp,
        '--no-playlist',
        '--default-search', 'ytsearch1',
        '--extractor-args', 'youtube:player_client=ios,web',
        '-x',
        '--audio-format', 'mp3',
        '--restrict-filenames',
        '--write-info-json',
        '--no-clean-info-json',
        '-o', File::Spec->catfile($incoming, '%(id)s.%(ext)s'),
        '--print', 'after_move:filepath',
        '--print', 'id',
        '--print', 'title',
    );

    if (defined($cookies) && $cookies ne '') {
        if (-r $cookies) {
            push @cmd, ('--cookies', $cookies);
        }
        else {
            $self->_logger(2, "YTDLP_COOKIES_FILE is configured but not readable: $cookies");
        }
    }

    if (defined($remote_components) && $remote_components ne '') {
        if ($remote_components =~ /\A[A-Za-z0-9_.:,-]+\z/) {
            push @cmd, ('--remote-components', $remote_components);
        }
        else {
            $self->_logger(2, "YTDLP_REMOTE_COMPONENTS has unsafe characters, ignored: $remote_components");
        }
    }

    push @cmd, $query;

    my $pid = fork();

    unless (defined $pid) {
        botNotice($bot, $ctx->nick, "Radio: could not start yt-dlp child process: $!");
        return;
    }

    if ($pid == 0) {
        open STDOUT, '>', $stdout or exit 126;
        open STDERR, '>', $stderr or exit 126;
        exec @cmd;
        exit 127;
    }

    $bot->{_radio_request_download} = {
        active           => 1,
        pid              => $pid,
        query            => $query,
        started          => time(),
        stdout           => $stdout,
        stderr           => $stderr,
        loop             => $loop,
        timer            => undef,
        cancel_requested => 0,
        term_sent_at     => undef,
        timed_out        => 0,
    };

    $self->_say($ctx, "Radio: download/search started: $query");

    my $timer;
    $timer = IO::Async::Timer::Countdown->new(
        delay => 1,
        on_expire => sub {
            my $job = $bot->{_radio_request_download} || {};

            # mb125: if an admin cancelled the job and removed the timer, do not
            # run the normal completion path later from a stale closure.
            if (!$job->{active} || $job->{cancel_requested} || (($job->{pid} // 0) != $pid)) {
                eval { $loop->remove($timer) };
                return;
            }

            my $res = waitpid($pid, WNOHANG);

            if ($res == 0) {
                my $started = $job->{started} // time();

                if ((time() - $started) > $timeout) {
                    # MB307: remember that this completion path is a timeout.
                    # A process killed by a signal has a zero high-byte exit
                    # status, so `$? >> 8` alone would incorrectly look like
                    # success and produce a misleading "no MP3" message.
                    $job->{timed_out} = 1;

                    # Non-blocking timeout escalation:
                    # first tick sends TERM, later tick sends KILL if needed.
                    if (!$job->{term_sent_at}) {
                        kill 'TERM', $pid;
                        $job->{term_sent_at} = time();
                        $timer->start;
                        return;
                    }

                    if ((time() - $job->{term_sent_at}) >= 1) {
                        kill 'KILL', $pid if kill(0, $pid);
                    }

                    $timer->start;
                    return;
                }

                $timer->start;
                return;
            }

            # Capture the child status immediately: later cleanup code may
            # execute callbacks or other operations that should not be allowed
            # to obscure the wait status returned by waitpid().
            my $wait_status = $?;
            my $timedout    = $job->{timed_out} ? 1 : 0;

            eval { $loop->remove($timer) };
            $bot->{_radio_request_download} = {};

            if ($res < 0) {
                my $wait_error = $! || 'unknown waitpid error';
                $self->_logger(0, "waitpid failed for yt-dlp pid=$pid: $wait_error");
                $self->_finish_download(
                    ctx      => $ctx,
                    query    => $query,
                    id_user  => $uid,
                    stdout   => $stdout,
                    stderr   => $stderr,
                    exitcode => 255,
                    timedout => $timedout,
                );
                return;
            }

            my ($exit, $signal) = _decode_wait_status($wait_status, $timedout);
            $self->_logger(2, "yt-dlp pid=$pid ended from signal $signal")
                if $signal && !$timedout;

            $self->_finish_download(
                ctx      => $ctx,
                query    => $query,
                id_user  => $uid,
                stdout   => $stdout,
                stderr   => $stderr,
                exitcode => $exit,
                timedout => $timedout,
            );
        },
    );

    $bot->{_radio_request_download}->{timer} = $timer;
    $bot->{_radio_request_download}->{loop}  = $loop;

    $loop->add($timer);
    $timer->start;

    logBot($bot, $ctx->message, $ctx->channel, 'play', 'download-start', $query);
    return 1;
}

sub _cleanup_jobdir {
    my ($self, $jobdir, $max_age) = @_;

    $max_age ||= 3600;
    return unless defined($jobdir) && -d $jobdir;

    opendir my $dh, $jobdir or return;
    my $now = time();

    while (defined(my $name = readdir $dh)) {
        next unless $name =~ /^yt-dlp\.\d+\.\d+\.\d+\.(?:out|err)$/;

        my $path = File::Spec->catfile($jobdir, $name);
        next unless -f $path;

        my $mtime = (stat($path))[9] || next;
        next unless ($now - $mtime) > $max_age;

        unlink $path;
    }

    closedir $dh;
}

sub _read_file {
    my ($path, $limit) = @_;

    $limit ||= 4096;
    return '' unless defined($path) && -r $path;

    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh> // '';
    close $fh;

    return length($text) > $limit ? substr($text, 0, $limit) : $text;
}

# Decode Perl's raw child wait status into a conventional exit code.
# Signal-terminated children encode the signal in the low bits, which means
# simply shifting by eight incorrectly returns zero. Timeout is represented by
# 124, matching the conventional `timeout(1)` status.
sub _decode_wait_status {
    my ($wait_status, $timedout) = @_;

    $wait_status = 0 unless defined $wait_status;
    $timedout = $timedout ? 1 : 0;

    my $signal   = $wait_status & 127;
    my $exitcode = $wait_status >> 8;

    return (124, $signal) if $timedout;
    return (128 + $signal, $signal) if $signal;

    return ($exitcode, 0);
}

sub _info_json_path_for_mp3 {
    my ($path) = @_;

    return undef unless defined($path) && $path ne '';

    my $json = $path;
    $json =~ s/\.[^.]+$/.info.json/;

    return $json;
}

sub _metadata_from_info_json {
    my ($self, $path) = @_;

    my $json_path = _info_json_path_for_mp3($path);
    return ('', 'Unknown', '') unless defined($json_path) && -r $json_path;

    open my $fh, '<:encoding(UTF-8)', $json_path or do {
        $self->_logger(2, "could not read yt-dlp info json: $json_path: $!");
        return ('', 'Unknown', '');
    };

    local $/;
    my $raw = <$fh> // '';
    close $fh;

    my $info = eval { decode_json($raw) };
    unless ($info && ref($info) eq 'HASH') {
        my $err = $@ || 'decode_json returned no hash';
        chomp $err;
        $self->_logger(2, "could not decode yt-dlp info json $json_path: $err");
        return ('', 'Unknown', '');
    }

    my $id = $info->{id} // '';

    my $artist =
           $info->{artist}
        // $info->{creator}
        // $info->{uploader}
        // $info->{channel}
        // 'Unknown';

    my $title = $info->{title} // '';

    $artist =~ s/^\s+|\s+$//g if defined $artist;
    $title  =~ s/^\s+|\s+$//g if defined $title;

    $artist = 'Unknown' unless defined($artist) && $artist ne '';

    return ($id, $artist, $title);
}

sub _classify_ytdlp_error {
    my ($self, $raw, $exitcode, $timedout) = @_;

    $raw //= '';
    $raw =~ s/\s+/ /g;
    $raw =~ s/^\s+|\s+$//g;

    my $cookies = $self->_conf_value('YTDLP_COOKIES_FILE', '');
    my $wiki_hint = 'See Mediabot v3 wiki: Radio / YouTube cookies.';

    return 'yt-dlp timed out while downloading. Try again later, or cancel/retry if YouTube is slow.'
        if $timedout;

    if ($raw =~ /cookies are no longer valid/i
        || $raw =~ /account cookies are no longer valid/i
        || $raw =~ /rotated in the browser/i
        || $raw =~ /cookie.*(?:invalid|expired|stale)/i) {
        return "YouTube rejected cookies.txt: the cookies look expired or rotated by the browser. Re-export a fresh cookies.txt file. $wiki_hint";
    }

    if ($raw =~ /Sign in to confirm you.?re not a bot/i
        || $raw =~ /confirm you.?re not a bot/i
        || $raw =~ /Use --cookies-from-browser or --cookies/i
        || $raw =~ /authentication/i) {
        if (defined($cookies) && $cookies ne '') {
            return "YouTube requires valid login cookies, but the configured cookies.txt was not accepted. Refresh cookies.txt or switch later to the Chromium/browser-profile workflow. $wiki_hint";
        }
        return "YouTube requires login cookies for this request. Configure YTDLP_COOKIES_FILE outside the repository. $wiki_hint";
    }

    if ($raw =~ /GVS PO Token/i
        || $raw =~ /po_token/i
        || $raw =~ /HTTP Error 403/i
        || $raw =~ /\b403\b.*(?:Forbidden|YouTube|client|formats)/i) {
        return "YouTube blocked this download with a 403/player-token challenge. cookies.txt may be stale, or YouTube changed its checks. Refresh cookies.txt; if it persists, revisit the Chromium/browser-profile plan. $wiki_hint";
    }

    if ($raw =~ /Signature solving failed/i
        || $raw =~ /n challenge solving failed/i
        || $raw =~ /challenge solver/i) {
        return "YouTube challenge solving failed. Check YTDLP_REMOTE_COMPONENTS=ejs:github and the JavaScript runtime, then retry. $wiki_hint";
    }

    if ($raw =~ /Only images are available for download/i
        || $raw =~ /Requested format is not available/i
        || $raw =~ /No video formats found/i
        || $raw =~ /No audio formats found/i) {
        return "yt-dlp could not find a usable audio format for this YouTube result. This is often caused by stale cookies or a YouTube player challenge. $wiki_hint";
    }

    if ($raw =~ /HTTP Error 429/i
        || $raw =~ /Too Many Requests/i
        || $raw =~ /rate.?limit/i) {
        return 'YouTube rate-limited this bot. Wait before retrying; do not hammer m play.';
    }

    if ($raw =~ /Video unavailable/i
        || $raw =~ /This video is unavailable/i
        || $raw =~ /Private video/i
        || $raw =~ /has been removed/i) {
        return 'YouTube says this video is unavailable, private, removed, or blocked.';
    }

    if ($raw =~ /Unsupported URL/i) {
        return 'yt-dlp rejected this request: unsupported URL or search syntax.';
    }

    if ($raw =~ /Unable to download API page/i
        || $raw =~ /Unable to extract/i
        || $raw =~ /Failed to extract/i
        || $raw =~ /HTTP Error 400/i) {
        return 'yt-dlp could not extract metadata for this result. Try another search or refresh yt-dlp/cookies if it repeats.';
    }

    if ($raw =~ /Permission denied/i) {
        return 'Local download failed: permission denied while writing the MP3 or job files.';
    }

    if ($raw =~ /No space left on device/i) {
        return 'Local download failed: no space left on device.';
    }

    if ($raw =~ /unable to open for writing/i
        || $raw =~ /cannot write/i
        || $raw =~ /Read-only file system/i) {
        return 'Local download failed: Mediabot cannot write to the incoming MP3/job directory.';
    }

    if ($raw ne '') {
        my $short = substr($raw, 0, 180);
        $short =~ s/\s+\z//;
        return "yt-dlp failed with an unclassified error. Check logs for details. Short error: $short";
    }

    return "yt-dlp exited with code $exitcode but did not return a useful error message.";
}

sub _finish_download {
    my ($self, %args) = @_;

    my $ctx      = $args{ctx};
    my $query    = $args{query};
    my $uid      = $args{id_user} || 0;
    my $stdout   = $args{stdout};
    my $stderr   = $args{stderr};
    my $exitcode = $args{exitcode};
    my $timedout = $args{timedout} ? 1 : 0;

    my $bot = $self->{bot};

    my $out = _read_file($stdout, 16384);
    my $err = _read_file($stderr, 4096);

    unlink $stdout if defined($stdout) && -e $stdout;
    unlink $stderr if defined($stderr) && -e $stderr;

    if ($exitcode != 0) {
        my $raw = $err || $out || "yt-dlp exited with code $exitcode";
        my $msg = $self->_classify_ytdlp_error($raw, $exitcode, $timedout);
        $msg =~ s/\s+/ /g;
        $msg = substr($msg, 0, 360);
        $self->_say($ctx, "Radio: download failed: $msg");
        logBot($bot, $ctx->message, $ctx->channel, 'play', ($timedout ? 'download-timeout' : 'download-failed'), $query);
        return;
    }

    my @lines = grep { defined($_) && $_ ne '' } split(/\n/, $out);

    my $path;
    for my $line (@lines) {
        if ($line =~ m{^/.*\.mp3$}i && -r $line) {
            $path = $line;
            last;
        }
    }

    unless ($path) {
        $self->_say($ctx, "Radio: download finished, but no readable MP3 file was produced.");
        logBot($bot, $ctx->message, $ctx->channel, 'play', 'download-no-file', $query);
        return;
    }

    my ($ytid, $artist, $title) = $self->_metadata_from_info_json($path);

    # Fallback for older yt-dlp versions or missing info-json files.
    for my $line (@lines) {
        next if $line eq $path;
        if (!$ytid && $line =~ /^[A-Za-z0-9_-]{8,20}$/) {
            $ytid = $line;
            next;
        }
        if (!$title) {
            $title = $line;
        }
    }

    $title  ||= basename($path);
    $artist ||= 'Unknown';

    my $folder   = dirname($path);
    my $filename = basename($path);

    $self->_insert_mp3(
        id_user    => $uid,
        id_youtube => $ytid,
        folder     => $folder,
        filename   => $filename,
        artist     => $artist,
        title      => $title,
    );

    my $liq = $self->_liquidsoap_client;
    my ($ok, $response) = $liq->push($path);

    unless ($ok) {
        $self->_say($ctx, "Radio: download succeeded, but Liquidsoap could not queue the MP3: $response");
        logBot($bot, $ctx->message, $ctx->channel, 'play', 'push-failed', $query);
        return;
    }

    $self->_say($ctx, "Radio: downloaded, cached and queued: $artist - $title");
    logBot($bot, $ctx->message, $ctx->channel, 'play', 'queued', $query);
    return;
}

sub _find_existing_mp3_id {
    my ($self, %row) = @_;

    my $dbh = $self->{bot}->{dbh};
    return undef unless $dbh;

    # Strongest key first: YouTube id, when available.
    if (defined($row{id_youtube}) && $row{id_youtube} ne '') {
        my $sth = $dbh->prepare(q{
            SELECT id_mp3
            FROM MP3
            WHERE id_youtube = ?
            ORDER BY id_mp3 DESC
            LIMIT 1
        });

        if ($sth && $sth->execute($row{id_youtube})) {
            my ($id) = $sth->fetchrow_array;
            $sth->finish;
            return $id if $id;
        }
        else {
            $self->_logger(1, "MP3 id_youtube duplicate check failed: $DBI::errstr");
            $sth->finish if $sth;
        }
    }

    # Fallback key: same file path.
    if (defined($row{folder}) && $row{folder} ne ''
        && defined($row{filename}) && $row{filename} ne '') {
        my $sth = $dbh->prepare(q{
            SELECT id_mp3
            FROM MP3
            WHERE folder = ? AND filename = ?
            ORDER BY id_mp3 DESC
            LIMIT 1
        });

        if ($sth && $sth->execute($row{folder}, $row{filename})) {
            my ($id) = $sth->fetchrow_array;
            $sth->finish;
            return $id if $id;
        }
        else {
            $self->_logger(1, "MP3 path duplicate check failed: $DBI::errstr");
            $sth->finish if $sth;
        }
    }

    return undef;
}


sub import_directory {
    my ($self, %args) = @_;

    my $dir    = $args{dir} // $self->_conf_value('YOUTUBEDL_INCOMING', '');
    my $uid    = $args{id_user} || 0;
    my $limit  = $args{limit} || 500;

    $dir =~ s/^\s+|\s+$//g if defined $dir;

    return (0, "empty directory", undef) unless defined($dir) && $dir ne '';
    return (0, "directory does not exist: $dir", undef) unless -d $dir;
    return (0, "directory is not readable: $dir", undef) unless -r $dir;

    my @mp3;

    find(
        {
            wanted => sub {
                return if @mp3 >= $limit;
                return unless -f $_;
                return unless $_ =~ /\.mp3\z/i;
                return unless -r $_;

                push @mp3, $File::Find::name;
            },
            no_chdir => 1,
        },
        $dir,
    );

    my $seen = scalar @mp3;
    my $ok_count = 0;
    my $fail_count = 0;
    my @examples;

    for my $path (sort @mp3) {
        my ($ok, $res) = $self->import_local_file(
            path    => $path,
            id_user => $uid,
        );

        if ($ok) {
            $ok_count++;
            push @examples, "$res->{artist} - $res->{title}" if @examples < 5;
        }
        else {
            $fail_count++;
            $self->_logger(2, "radio importdir failed for $path: $res");
        }
    }

    return (1, {
        dir        => $dir,
        seen       => $seen,
        imported   => $ok_count,
        failed     => $fail_count,
        limit      => $limit,
        examples   => \@examples,
        truncated  => (@mp3 >= $limit ? 1 : 0),
    });
}


sub import_local_file {
    my ($self, %args) = @_;

    my $path   = $args{path}   // '';
    my $artist = $args{artist} // '';
    my $title  = $args{title}  // '';
    my $uid    = $args{id_user} || 0;

    $path =~ s/^\s+|\s+$//g;

    return (0, 'empty path') unless $path ne '';
    return (0, "file is not readable: $path") unless -r $path;
    return (0, "not an mp3 file: $path") unless $path =~ /\.mp3\z/i;

    my $folder   = dirname($path);
    my $filename = basename($path);

    my ($json_id, $json_artist, $json_title) = $self->_metadata_from_info_json($path);

    my $ytid = _extract_youtube_id($filename) || $json_id || '';

    $artist = $json_artist if (!defined($artist) || $artist eq '' || $artist eq 'Unknown')
        && defined($json_artist) && $json_artist ne '' && $json_artist ne 'Unknown';

    $title = $json_title if (!defined($title) || $title eq '')
        && defined($json_title) && $json_title ne '';

    if ((!defined($artist) || $artist eq '') && (!defined($title) || $title eq '')) {
        my $base = $filename;
        $base =~ s/\.mp3\z//i;
        $base =~ s/_/ /g;

        if ($base =~ /^(.+?)\s+-\s+(.+)$/) {
            ($artist, $title) = ($1, $2);
        }
        else {
            $artist = 'Unknown';
            $title  = $base;
        }
    }

    $artist = 'Unknown' unless defined($artist) && $artist ne '';
    $title  = $filename  unless defined($title)  && $title  ne '';

    my $id = $self->_insert_mp3(
        id_user    => $uid,
        id_youtube => $ytid,
        folder     => $folder,
        filename   => $filename,
        artist     => $artist,
        title      => $title,
    );

    return (0, 'MP3 database insert/update failed') unless $id;

    return (1, {
        id_mp3     => $id,
        id_youtube => $ytid,
        folder     => $folder,
        filename   => $filename,
        artist     => $artist,
        title      => $title,
        path       => $path,
    });
}

sub _insert_mp3 {
    my ($self, %row) = @_;

    my $dbh = $self->{bot}->{dbh};
    return unless $dbh;

    my %clean = (
        id_user    => $row{id_user} || 0,
        id_youtube => $row{id_youtube} || '',
        folder     => $row{folder} || '',
        filename   => $row{filename} || '',
        artist     => $row{artist} || 'Unknown',
        title      => $row{title} || $row{filename} || 'Unknown',
    );

    if (my $existing_id = $self->_find_existing_mp3_id(%clean)) {
        my $sql = q{
            UPDATE MP3
            SET id_user = ?,
                id_youtube = ?,
                folder = ?,
                filename = ?,
                artist = ?,
                title = ?
            WHERE id_mp3 = ?
        };

        my $sth = $dbh->prepare($sql);
        unless ($sth && $sth->execute(
            $clean{id_user},
            $clean{id_youtube},
            $clean{folder},
            $clean{filename},
            $clean{artist},
            $clean{title},
            $existing_id,
        )) {
            $self->_logger(1, "MP3 update failed for id_mp3=$existing_id: $DBI::errstr");
            $sth->finish if $sth;
            return;
        }

        $sth->finish;
        $self->_logger(4, "MP3 cache row updated id_mp3=$existing_id title=$clean{title}");
        return $existing_id;
    }

    my $sql = q{
        INSERT INTO MP3 (id_user, id_youtube, folder, filename, artist, title)
        VALUES (?, ?, ?, ?, ?, ?)
    };

    my $sth = $dbh->prepare($sql);
    unless ($sth && $sth->execute(
        $clean{id_user},
        $clean{id_youtube},
        $clean{folder},
        $clean{filename},
        $clean{artist},
        $clean{title},
    )) {
        $self->_logger(1, "MP3 insert failed: $DBI::errstr");
        $sth->finish if $sth;
        return;
    }

    my $new_id = eval { $dbh->last_insert_id(undef, undef, undef, undef) } || undef;
    $sth->finish;

    $self->_logger(4, "MP3 cache row inserted id_mp3=" . ($new_id // '?') . " title=$clean{title}");
    return $new_id || 1;
}

1;
