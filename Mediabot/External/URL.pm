package Mediabot::External::URL;
# =============================================================================
# Mediabot::External::URL — URL title display, Instagram, Facebook, X/Twitter,
#                           Apple Music, generic titles
# =============================================================================
# mb99-R1: extrait de Mediabot::External.
# =============================================================================

use strict;
use warnings;
use utf8;   # mb621-B1: les litteraux de ce fichier sont des CARACTERES.
            # Sans cela ils sont des OCTETS, et interpoler une variable
            # venue d'IRC (mediabot.pl decode les messages entrants) fait
            # basculer toute la chaine : les octets sont relus en latin-1
            # puis re-encodes a l'envoi -> mojibake (« humeur Ã©lectrique »).

use Exporter 'import';
use JSON::MaybeXS;
use Mediabot::AsyncWorker;
use URI::Escape qw(uri_escape_utf8 uri_escape);
use HTML::Entities qw(decode_entities);
use HTML::Entities '%entity2char';
use String::IRC;
use Encode qw(encode decode);
use Time::HiRes qw(usleep);
use IPC::Open3;
use Symbol qw(gensym);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Select;
use POSIX qw(WNOHANG);

our $VERSION = '1.00';

our @EXPORT_OK = qw(
    _extract_url
    _decode_html
    _decode_http_content_utf8
    _fetch_url_chromium_dumpdom
    _handle_instagram
    _handle_applemusic
    _facebook_url
    _facebook_title_from_html
    _facebook_fallback_title_from_url
    _handle_facebook
    _x_url
    _x_title_from_html
    _x_fallback_title_from_url
    _handle_x_twitter
    _clean_generic_url_title
    _handle_generic_title
    displayUrlTitle
);

sub _extract_url {
    my ($text) = @_;
    return undef unless defined $text;

    # Keep the first HTTP(S) URL found in the message.
    # Then strip common punctuation that users often type just after a link.
    return undef unless $text =~ m{(https?://\S+)}i;

    my $url = $1;

    # Remove terminal punctuation that is almost never part of the URL in IRC
    # messages. This fixes cases like:
    #   https://example.org/foo).
    #   https://example.org/foo,
    #   https://example.org/foo]
    #
    # mb405-B1: MAIS ne retirer une ')' ou ']' finale que si elle est NON
    # APPARIÉE dans l'URL. Les URLs Wikipédia se terminent très souvent par
    # une parenthèse LÉGITIME (…/Talos_(mythologie)) : l'ancien strip aveugle
    # la coupait -> mauvaise page / 404. On strippe la ponctuation pure, puis
    # on ne consomme les fermantes finales que tant qu'elles sont en excès.
    $url =~ s/[.,!?;:]+$//;
    while ($url =~ /[)\]]$/) {
        my $last = substr($url, -1);
        my ($open, $close) = $last eq ')' ? ('(', ')') : ('[', ']');
        my $n_open  = () = $url =~ /\Q$open\E/g;
        my $n_close = () = $url =~ /\Q$close\E/g;
        last if $n_close <= $n_open;   # appariée -> elle fait partie de l'URL
        chop $url;
        $url =~ s/[.,!?;:]+$//;
    }

    # If the URL is wrapped in a single trailing quote, remove it.
    $url =~ s/["']+$//;

    return $url;
}

# ---------------------------------------------------------------------------
# _decode_html($str) — decode HTML entities in a string
# ---------------------------------------------------------------------------
sub _decode_html {
    my ($str) = @_;
    return '' unless defined $str;
    my $regex = "&(?:" . join("|", map { (my $k = $_) =~ s/;\z//; $k } keys %entity2char) . ");";
    # mb495: also trigger on HEX numeric entities (&#xa0; &#x442; &#x1f979;) —
    # they matched neither the named-entity regex nor the decimal one, so
    # Facebook reel titles reached IRC raw-encoded.
    $str = decode_entities($str) if ($str =~ /$regex/ || $str =~ /&#[0-9]+;/ || $str =~ /&#x[0-9a-fA-F]+;/);
    $str =~ s/\r|\n/ /g;
    $str =~ s/\s{2,}/ /g;
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

sub _decode_http_content_utf8 {
    my ($self, $content, $context) = @_;
    return '' unless defined $content;

    my $decoded = $content;

    eval {
        $decoded = decode('UTF-8', $content, 1);
        1;
    } or do {
        my $ctx = defined $context ? $context : 'unknown';
        $self->{logger}->log(4, "_decode_http_content_utf8() UTF-8 decode failed for $ctx");
    };

    return $decoded;
}

# Wait for Chromium without allowing a child that closed its pipes early to
# block the whole IRC event loop indefinitely. Returns:
#   ($waited_pid, $raw_wait_status, $timed_out, $error)
sub _wait_chromium_child {
    my ($pid, $deadline) = @_;

    return (-1, undef, 0, 'missing child pid')
        unless defined($pid) && $pid > 0;

    $deadline = time() unless defined $deadline;

    while (1) {
        my $waited = waitpid($pid, WNOHANG);

        return ($waited, $?, 0, '') if $waited == $pid;
        return (-1, undef, 0, "waitpid failed: $!") if $waited == -1;

        last if time() >= $deadline;
        usleep(50_000);
    }

    # The pipes are closed but the child is still alive at the request
    # deadline. Give TERM a short grace period, then escalate to KILL.
    kill 'TERM', $pid;
    my $term_deadline = time() + 0.50;

    while (time() < $term_deadline) {
        my $waited = waitpid($pid, WNOHANG);

        return ($waited, $?, 1, '') if $waited == $pid;
        return (-1, undef, 1, "waitpid failed after TERM: $!") if $waited == -1;

        usleep(50_000);
    }

    kill 'KILL', $pid;
    my $waited = waitpid($pid, 0);

    return ($waited, $?, 1, '') if $waited == $pid;
    return (-1, undef, 1, "waitpid failed after KILL: $!");
}

# Convert Perl's raw wait status to a conventional process result. A child
# killed by a signal stores that signal in the low bits, so `$status >> 8`
# alone incorrectly reports success (0).
sub _decode_chromium_wait_status {
    my ($status) = @_;
    $status = 0 unless defined $status;

    my $signal = $status & 127;
    my $exit   = ($status >> 8) & 255;

    return (128 + $signal, $signal) if $signal;
    return ($exit, 0);
}

sub _fetch_url_chromium_dumpdom {
    my ($self, $url, %opts) = @_;
    return undef unless defined $url && $url ne '';

    # mb448-B1 (revue sécurité pré-release, classe exec/argv) : cette fonction
    # est la DERNIÈRE frontière avant open3(). $url est le dernier élément de
    # l'argv Chromium ; une chaîne commençant par '-' serait interprétée comme
    # une OPTION Chromium (même classe que l'injection yt-dlp corrigée en
    # mb417). Tous les appelants actuels valident ^https?:// en amont, mais la
    # frontière ne doit pas dépendre de la discipline des appelants (cf. la
    # même règle dans ScriptRunner::run_plan). On n'accepte ici que des URLs
    # http(s) absolues — ce qui exclut structurellement tout argument-option.
    unless ($url =~ m{\Ahttps?://}i) {
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() refused non-http(s) argument");
        return undef;
    }

    my $chromium = '/usr/bin/chromium';
    unless (-x $chromium) {
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() chromium not found at $chromium");
        return undef;
    }

    # Chromium timeouts configurable via conf.
    my $_default_vtb   = int(eval { $self->{conf}->get('chromium.VIRTUAL_TIME_BUDGET') } // 3500);
    my $_default_alarm = int(eval { $self->{conf}->get('chromium.ALARM_TIMEOUT') }       // 12);

    $_default_vtb   = 1000  if $_default_vtb < 1000;
    $_default_vtb   = 30000 if $_default_vtb > 30000;
    $_default_alarm = 5     if $_default_alarm < 5;
    $_default_alarm = 60    if $_default_alarm > 60;

    my $virtual_time_budget = $opts{virtual_time_budget} // $_default_vtb;
    my $alarm_timeout       = $opts{alarm_timeout}       // $_default_alarm;
    my $lang                = $opts{lang}                // 'fr-FR';
    my $user_agent          = $opts{user_agent}          // 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36';

    my $max_stdout = int($opts{max_stdout} // (2 * 1024 * 1024));
    my $max_stderr = int($opts{max_stderr} // (256 * 1024));

    # mb493: chromium was dying instantly with SIGTRAP (signal 5) in prod.
    # Root causes for a systemd-run daemon: the default profile dir lives in
    # a confined/unwritable HOME, and concurrent/stale runs fight over the
    # profile SingletonLock; crashpad also traps when it cannot write.
    # Fix: a unique throwaway --user-data-dir per invocation under /tmp,
    # opportunistically purging profiles older than 10 minutes (daemon-safe:
    # no cleanup needed on every return path, the next call sweeps).
    my $profile_base = '/tmp/mediabot-chromium';
    mkdir $profile_base unless -d $profile_base;
    if (opendir(my $dh, $profile_base)) {
        my $now = time();
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$profile_base/$e";
            my $m = (stat($p))[9];
            next unless defined $m;
            if ($now - $m > 600) {
                eval { require File::Path; File::Path::remove_tree($p); };
            }
        }
        closedir $dh;
    }
    my $profile_dir = sprintf('%s/p%d.%d.%d', $profile_base, $$, time(), int(rand(1_000_000)));

    my @cmd = (
        $chromium,
        '--headless',                       # mb493: modern default (was =new, brittle on recent Chrome)
        "--user-data-dir=$profile_dir",     # mb493: unique throwaway profile
        '--no-first-run',                   # mb493: skip first-run machinery
        '--no-default-browser-check',
        '--disable-crash-reporter',         # mb493: crashpad traps in confined envs
        '--disable-breakpad',
        '--disable-gpu',
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--disable-background-networking',
        '--disable-default-apps',
        '--disable-extensions',
        '--disable-sync',
        '--disable-notifications',
        '--disable-popup-blocking',
        '--mute-audio',
        '--metrics-recording-only',
        '--disable-blink-features=AutomationControlled',
        '--window-size=1366,900',
        "--lang=$lang",
        "--user-agent=$user_agent",
        "--virtual-time-budget=$virtual_time_budget",
        '--dump-dom',
        $url,
    );

    $self->{logger}->log(
        4,
        "_fetch_url_chromium_dumpdom() budget=$virtual_time_budget alarm=$alarm_timeout exec: " . join(' ', @cmd)
    );

    my $stderr = gensym;
    my $pid;
    my $stdout = '';
    my $stderr_txt = '';
    my $deadline = time() + $alarm_timeout;

    my $ok = eval {
        $pid = open3('/dev/null', my $out, $stderr, @cmd);

        # Important:
        # Chromium can write a lot to stderr. If stderr is not drained while
        # stdout is being read, Chromium may block on a full stderr pipe and
        # the wrapper eventually reports ALARM. Drain both pipes together.
        for my $fh ($out, $stderr) {
            my $flags = fcntl($fh, F_GETFL, 0);
            fcntl($fh, F_SETFL, $flags | O_NONBLOCK) if defined $flags;
        }

        my $sel = IO::Select->new();
        $sel->add($out);
        $sel->add($stderr);

        my %kind = (
            fileno($out)    => 'stdout',
            fileno($stderr) => 'stderr',
        );

        while ($sel->count) {
            my $remaining = $deadline - time();
            die "ALARM\n" if $remaining <= 0;

            my @ready = $sel->can_read($remaining > 0.1 ? 0.1 : $remaining);
            next unless @ready;

            for my $fh (@ready) {
                my $chunk = '';
                my $n = sysread($fh, $chunk, 65536);

                if (!defined $n) {
                    next if $!{EAGAIN} || $!{EWOULDBLOCK} || $!{EINTR};
                    die "read failed: $!\n";
                }

                if ($n == 0) {
                    $sel->remove($fh);
                    close($fh);
                    next;
                }

                if (($kind{fileno($fh)} // '') eq 'stdout') {
                    $stdout .= $chunk if length($stdout) < $max_stdout;
                }
                else {
                    $stderr_txt .= $chunk if length($stderr_txt) < $max_stderr;
                }
            }
        }

        1;
    };

    if (!$ok) {
        my $err = $@ || 'unknown error';

        if ($pid) {
            eval { kill 'TERM', $pid };

            my $reaped = 0;
            for (1 .. 10) {
                my $waited = waitpid($pid, WNOHANG);
                if ($waited == $pid || $waited == -1) {
                    $reaped = 1;
                    last;
                }
                usleep(200_000);
            }

            unless ($reaped) {
                eval { kill 'KILL', $pid };
                waitpid($pid, 0);
            }
        }

        $err =~ s/\s+$//;
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() failed for $url: $err");

        if (defined $stderr_txt && $stderr_txt ne '') {
            my $errlog = substr($stderr_txt, 0, 500);
            $errlog =~ s/\s+/ /g;
            $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() stderr-before-fail=$errlog");
        }

        return undef;
    }

    # MB308: stdout/stderr reaching EOF does not guarantee that Chromium
    # itself has exited. Reap it only within the original request deadline so
    # a child that closes both pipes and keeps running cannot freeze Mediabot.
    my ($waited, $wait_status, $reap_timedout, $wait_error)
        = _wait_chromium_child($pid, $deadline);

    if ($waited != $pid) {
        $wait_error ||= 'unknown waitpid failure';
        $self->{logger}->log(3,
            "_fetch_url_chromium_dumpdom() could not reap chromium pid=$pid for $url: $wait_error");
        return undef;
    }

    my ($rc, $signal) = _decode_chromium_wait_status($wait_status);

    if ($reap_timedout) {
        $self->{logger}->log(3,
            "_fetch_url_chromium_dumpdom() chromium exceeded alarm timeout after closing its pipes for $url");
        return undef;
    }

    if ($signal) {
        $self->{logger}->log(3,
            "_fetch_url_chromium_dumpdom() chromium terminated by signal $signal for $url");
        # mb493: surface WHY it died — this was never logged on the signal
        # path, making prod crashes (SIGTRAP) undiagnosable.
        if (defined $stderr_txt && $stderr_txt ne '') {
            my $errlog = substr($stderr_txt, 0, 700);
            $errlog =~ s/[\r\n]+/ | /g;
            $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() chromium stderr: $errlog");
        }
        return undef;
    }

    eval {
        $stdout = decode('UTF-8', $stdout, 1);
        1;
    } or do {
        $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() UTF-8 decode failed for $url");
    };

    my $len = length($stdout // '');
    $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() rc=$rc signal=$signal bytes=$len for $url");

    if (defined $stderr_txt && $stderr_txt ne '') {
        my $errlog = substr($stderr_txt, 0, 500);
        $errlog =~ s/\s+/ /g;
        $self->{logger}->log(4, "_fetch_url_chromium_dumpdom() stderr=$errlog");
    }

    unless ($rc == 0 && defined $stdout && $stdout ne '') {
        $self->{logger}->log(3, "_fetch_url_chromium_dumpdom() chromium returned no usable DOM for $url");
        return undef;
    }

    return $stdout;
}




# ---------------------------------------------------------------------------
# Mediabot::External::_chanset_ok($self, $channel, $chanset_name)
# Returns 1 if the chanset is enabled on this channel (or if chanset doesn't
# exist in CHANSET_LIST at all, which means the feature is always-on).
# Returns 0 if the chanset exists but is NOT enabled on this channel.
# ---------------------------------------------------------------------------

sub _instagram_url_info {
    my ($url) = @_;

    return { kind => 'link', label => 'Instagram', icon => '🔗' }
        unless defined $url && $url ne '';

    my $path = $url;
    $path =~ s{\Ahttps?://(?:www\.)?instagram\.com}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};
    $path =~ s{\A/+}{};

    if ($path =~ m{\A(p|reel|tv)/([^/]+)\z}i) {
        my ($raw_kind, $ref) = (lc($1), $2);
        return {
            kind  => $raw_kind eq 'p' ? 'post' : $raw_kind,
            label => $raw_kind eq 'p' ? 'Post' : $raw_kind eq 'reel' ? 'Reel' : 'Video',
            icon  => $raw_kind eq 'p' ? '📷' : $raw_kind eq 'reel' ? '🎬' : '📺',
            ref   => $ref,
        };
    }

    if ($path =~ m{\Astories/highlights/([^/]+)\z}i) {
        return {
            kind  => 'highlight',
            label => 'Highlight',
            icon  => '✨',
            ref   => $1,
        };
    }

    if ($path =~ m{\Astories/([^/]+)/([^/]+)\z}i) {
        return {
            kind  => 'story',
            label => 'Story',
            icon  => '📖',
            owner => $1,
            ref   => $2,
        };
    }

    if ($path =~ m{\A([^/]+)\z} && $1 !~ /\A(?:accounts|about|direct|emails|explore|legal|privacy|reels?|stories|web)\z/i) {
        return {
            kind  => 'profile',
            label => 'Profile',
            icon  => '👤',
            owner => $1,
        };
    }

    return { kind => 'link', label => 'Instagram', icon => '🔗' };
}

sub _instagram_clean_meta_value {
    my ($value) = @_;
    return undef unless defined $value;

    $value = _decode_html($value);
    $value =~ s/[\r\n\t]+/ /g;
    $value =~ s/\s{2,}/ /g;
    $value =~ s/^\s+|\s+$//g;

    return undef if $value eq '';
    return undef if $value =~ /^Instagram$/i;
    return undef if $value =~ /create an account or log in to instagram/i;
    return undef if $value =~ /log in to instagram/i;

    return $value;
}

sub _instagram_meta_from_html {
    my ($html) = @_;
    return {} unless defined $html && $html ne '';

    my %meta;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        my %attr;

        while ($attrs =~ /\b([A-Za-z_:.-]+)\s*=\s*(["'])(.*?)\2/sig) {
            $attr{lc($1)} = $3;
        }

        my $key = lc($attr{property} // $attr{name} // '');
        next unless $key =~ /\A(?:og:title|og:description|twitter:title|twitter:description|description)\z/;
        next unless exists $attr{content};
        next if exists $meta{$key};

        my $value = _instagram_clean_meta_value($attr{content});
        $meta{$key} = $value if defined $value;
    }

    if ($html =~ /<title[^>]*>(.*?)<\/title>/si) {
        my $title = _instagram_clean_meta_value($1);
        $meta{title} = $title if defined $title;
    }

    return \%meta;
}

sub _instagram_parse_social_description {
    my ($desc) = @_;
    return undef unless defined $desc && $desc ne '';

    # With the crawler request forced to en-US Instagram commonly serves:
    #   55K likes, 282 comments - natgeo on April 1, 2025: "caption...".
    if ($desc =~ /^\s*([0-9][0-9.,]*\s*[KMB]?)\s+likes?,\s*([0-9][0-9.,]*\s*[KMB]?)\s+comments?\s+-\s+([A-Za-z0-9._]+)\s+on\s+(.+?):\s*["“](.*)["”]\.??\s*$/s) {
        my ($likes, $comments, $owner, $date, $caption) = ($1, $2, $3, $4, $5);
        for ($likes, $comments, $owner, $date, $caption) {
            $_ =~ s/\s+/ /g if defined $_;
            $_ =~ s/^\s+|\s+$//g if defined $_;
        }
        $caption =~ s/\.\z// if defined $caption && $caption =~ /\.\z/;

        return {
            likes    => $likes,
            comments => $comments,
            owner    => $owner,
            date     => $date,
            caption  => $caption,
        };
    }

    return undef;
}

sub _instagram_fetch_sync {
    my ($url) = @_;

    my $http = Mediabot::External::_make_http(
        timeout  => 4,
        max_size => 1024 * 1024,
        agent    => 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',
        default_headers => { 'accept-language' => 'en-US,en;q=0.8' },
    );

    my $res = eval { $http->get($url); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    unless ($res->{success}) {
        return {
            ok     => 0,
            status => int($res->{status} // 0),
            reason => substr(($res->{reason} // 'HTTP fetch failed'), 0, 160),
            meta   => {},
        };
    }

    my $content = $res->{content} // '';
    eval { $content = decode('UTF-8', $content, 1); 1 };

    my $meta = _instagram_meta_from_html($content);

    return {
        ok     => 1,
        status => int($res->{status} // 200),
        bytes  => length($content),
        meta   => $meta,
    };
}

sub _instagram_build_display {
    my ($url_info, $fetch) = @_;

    $url_info = {} unless ref($url_info) eq 'HASH';
    $fetch    = {} unless ref($fetch) eq 'HASH';

    my $meta = ref($fetch->{meta}) eq 'HASH' ? $fetch->{meta} : {};
    my $desc = $meta->{'og:description'}
        // $meta->{'twitter:description'}
        // $meta->{description};
    my $headline = $meta->{'og:title'}
        // $meta->{'twitter:title'}
        // $meta->{title};

    my @parts;
    push @parts, (($url_info->{icon} // '🔗') . ' ' . ($url_info->{label} // 'Instagram'));

    # Instagram can return a generic Story viewer shell for an unavailable
    # story id.  The title is generic and the description contains profile
    # counters, not story-specific content.  Suppress only that combination so
    # a real Story with useful metadata is still rendered normally.
    if (($url_info->{kind} // '') eq 'story'
        && defined($headline)
        && defined($desc)
        && $headline =~ /^Watch this story by .+ on Instagram before it disappears\.?$/i
        && $desc =~ /^\s*[0-9][0-9.,]*\s*[KMB]?\s+Followers,\s*
                      [0-9][0-9.,]*\s*[KMB]?\s+Following,\s*
                      [0-9][0-9.,]*\s*[KMB]?\s+Posts\s*$/ix) {
        $headline = undef;
        $desc = undef;
    }

    my $structured = _instagram_parse_social_description($desc);
    if ($structured) {
        my $owner = $structured->{owner} // $url_info->{owner};
        push @parts, '@' . $owner if defined $owner && $owner ne '';
        push @parts, '❤️ ' . $structured->{likes}
            if defined $structured->{likes} && $structured->{likes} ne '';
        push @parts, '💬 ' . $structured->{comments}
            if defined $structured->{comments} && $structured->{comments} ne '';
        push @parts, '📅 ' . $structured->{date}
            if defined $structured->{date} && $structured->{date} ne '';
        push @parts, $structured->{caption}
            if defined $structured->{caption} && $structured->{caption} ne '';
    }
    else {
        my $owner = $url_info->{owner};
        push @parts, '@' . $owner if defined $owner && $owner ne '';

        my @detail;
        if (defined $headline && $headline ne '' && $headline !~ /^Instagram$/i) {
            push @detail, $headline;
        }
        if (defined $desc && $desc ne '') {
            my $duplicate = @detail && index(lc($desc), lc($detail[0])) >= 0;
            push @detail, $desc unless $duplicate;
        }

        if (@detail) {
            push @parts, @detail;
        }
        elsif (($url_info->{kind} // '') ne 'profile') {
            push @parts, 'public details unavailable';
        }
    }

    my $display = join(' · ', grep { defined $_ && $_ ne '' } @parts);
    $display =~ s/\s+/ /g;
    $display =~ s/^\s+|\s+$//g;

    return $display ne '' ? $display : '🔗 Instagram';
}

sub _handle_instagram {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_instagram() start url=$url");

    my $cache_key = lc($url // '');

    # Preserve the existing badge/result cache (TTL 10 min).
    my $ig_cached = $self->{_instagram_cache}{$cache_key};
    if ($ig_cached && (time() - ($ig_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_instagram() cache hit for $url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $ig_cached->{msg}");
        return 1;
    }

    my $url_info = _instagram_url_info($url);

    my $finish = sub {
        my ($fetch, $worker_status) = @_;
        delete $self->{_instagram_pending}{$cache_key};

        $fetch = {} unless ref($fetch) eq 'HASH';
        my $status = int($fetch->{status} // 0);
        my $bytes  = int($fetch->{bytes} // 0);
        my $ok     = $fetch->{ok} ? 1 : 0;

        $self->{logger}->log(4,
            "_handle_instagram() fetch done ok=$ok status=$status bytes=$bytes worker="
            . (defined($worker_status) ? $worker_status : 'sync'));

        my $title = _instagram_build_display($url_info, $fetch);
        $title = Mediabot::Helpers::truncate_utf8($title, 300, '…');

        my $badge = String::IRC->new("[")->white('black');
        $badge   .= String::IRC->new("Instagram")->white('pink');
        $badge   .= String::IRC->new("]")->white('black');

        # Keep the historical Instagram badge exactly as-is. Reset immediately
        # afterwards so all rich details use the IRC client's normal foreground
        # and remain readable on both dark and light themes.
        my $msg = "$badge\x0f " . $title;
        $self->{_instagram_cache}{$cache_key} = { ts => time(), msg => $msg };

        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
        return 1;
    };

    # At runtime URL processing happens inside the IRC event loop. Never run
    # Instagram's network request there: even a normal timeout must not stall
    # PRIVMSG processing. Tests and isolated probes without an IO::Async loop
    # keep a deterministic synchronous adapter around the same fetch function.
    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self) eq 'HASH' || ref($self);

    if ($loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') }) {

        if ($self->{_instagram_pending}{$cache_key}) {
            $self->{logger}->log(4, "_handle_instagram() request already pending for $url");
            return 1;
        }
        $self->{_instagram_pending}{$cache_key} = time();

        my $adapter_done = 0;
        my $done = sub {
            my ($result) = @_;
            return if $adapter_done++;

            my $fetch = {};
            my $worker_status = 'failed';
            if (ref($result) eq 'HASH' && $result->{ok}) {
                $fetch = ref($result->{value}) eq 'HASH' ? $result->{value} : {};
                $worker_status = 'ok';
            }
            elsif (ref($result) eq 'HASH') {
                $worker_status = $result->{error} // 'failed';
            }

            eval { $finish->($fetch, $worker_status); 1 } or do {
                my $error = $@ || 'unknown Instagram completion error';
                $error =~ s/\s+/ /g;
                delete $self->{_instagram_pending}{$cache_key};
                $self->{logger}->log(1, "_handle_instagram() completion failed: $error");
            };
        };

        my $worker;
        my $launch_ok = eval {
            $worker = Mediabot::AsyncWorker->start(
                loop        => $loop,
                label       => 'instagram metadata',
                timeout     => 6,
                term_grace  => 0.2,
                force_grace => 1.0,
                max_output  => 16 * 1024,
                child       => sub {
                    return _instagram_fetch_sync($url);
                },
                on_done => $done,
            );
            1;
        };

        if (!$launch_ok && !$adapter_done) {
            my $error = $@ || 'AsyncWorker launch failed';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(2, "_handle_instagram() async launch failed: $error");
            $done->({ ok => 0, error => 'worker_setup' });
        }
        elsif (!$worker && !$adapter_done) {
            $done->({ ok => 0, error => 'worker_setup' });
        }

        return 1;
    }

    return $finish->(_instagram_fetch_sync($url), 'sync-no-loop');
}

# ---------------------------------------------------------------------------
# Mediabot::External::_handle_spotify($self, $message, $nick, $channel, $url)
# Parses <title> from Spotify page. Format: "Song - artist | Spotify"
# Also handles albums, playlists, podcasts via og:title.
# ---------------------------------------------------------------------------
# mb94-R1: toutes les subs _spotify_* et Mediabot::External::_handle_spotify sont dans
# Mediabot::External::Spotify (Mediabot/External/Spotify.pm)
# et importées en tête de ce fichier.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _handle_applemusic($self, $message, $nick, $channel, $url)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _am_duration_from_iso($iso) — Spotify-style IRC duration: "3m 33s", "1h02m03s"
# ---------------------------------------------------------------------------
sub _am_duration_from_iso {
    my ($iso) = @_;
    return undef unless defined $iso && $iso =~ /^P(?:[\d.]+D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?$/i;
    my ($h, $m, $s) = ($1 // 0, $2 // 0, int($3 // 0));
    return undef unless $h || $m || $s;
    return sprintf('%dh%02dm%02ds', $h, $m, $s) if $h;
    return sprintf('%dm %02ds', $m, $s);
}

sub _am_duration_from_ms {
    my ($ms) = @_;
    return undef unless defined $ms && $ms =~ /^\d+$/;

    my $total = int($ms / 1000);
    return undef if $total <= 0;

    my $h = int($total / 3600);
    my $m = int(($total % 3600) / 60);
    my $s = $total % 60;

    return sprintf('%dh%02dm%02ds', $h, $m, $s) if $h;
    return sprintf('%dm %02ds', $m, $s);
}

sub _applemusic_url_info {
    my ($url) = @_;

    my ($storefront) = ($url // '') =~ m{^https?://music\.apple\.com/([a-z]{2})(?:/|$)}i;
    $storefront = lc($storefront // 'us');

    my ($track_id) = ($url // '') =~ /[?&]i=(\d+)/;
    if (!defined $track_id) {
        ($track_id) = ($url // '') =~ m{/song/(?:[^/?#]+/)?(\d+)(?:[/?#]|$)}i;
    }

    return {
        storefront => $storefront,
        track_id   => $track_id,
    };
}

sub _applemusic_extract_details {
    my ($self, $html) = @_;
    my %am;
    return \%am unless defined $html && $html ne '';

    while ($html =~ m{<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>}sig) {
        my $raw  = _decode_html($1);
        my $data = eval { decode_json($raw) };
        next unless defined $data;
        my @objs = ref($data) eq 'ARRAY' ? @$data : ($data);
        for my $o (@objs) {
            next unless ref($o) eq 'HASH';
            my $t = $o->{'@type'} // '';
            $t = join(' ', @$t) if ref($t) eq 'ARRAY';
            if ($t =~ /MusicAlbum/i)                    { $am{type} //= 'album'; }
            elsif ($t =~ /MusicRecording|MusicSong/i)   { $am{type} //= 'song'; }
            elsif ($t =~ /MusicPlaylist/i)              { $am{type} //= 'playlist'; }
            if (my $a = $o->{byArtist}) {
                my @names = ref($a) eq 'ARRAY' ? map { ref($_) eq 'HASH' ? $_->{name} : $_ } @$a
                          : ref($a) eq 'HASH'  ? ($a->{name})
                          : ($a);
                @names = grep { defined && $_ ne '' } @names;
                $am{artist} //= join(', ', @names) if @names;
            }
            if (defined $o->{duration}) {
                my $d = _am_duration_from_iso($o->{duration});
                $am{duration} //= $d if defined $d;
            }
            if (defined $o->{datePublished} && $o->{datePublished} =~ /\b((?:19|20)\d{2})\b/) {
                $am{year} //= $1;
            }
            if (defined $o->{numTracks} && $o->{numTracks} =~ /^\d+$/) {
                $am{tracks} //= $o->{numTracks};
            }
            elsif (ref($o->{tracks} // $o->{track} // '') eq 'ARRAY') {
                my $n = scalar @{ $o->{tracks} // $o->{track} };
                $am{tracks} //= $n if $n;
            }
        }
    }

    my $desc;
    if    ($html =~ /<meta\s+property=["']og:description["']\s+content=(["'])(.*?)\1/is) { $desc = $2; }
    elsif ($html =~ /<meta\s+content=(["'])(.*?)\1\s+property=["']og:description["']/is) { $desc = $2; }
    elsif ($html =~ /<meta\s+name=["']description["']\s+content=(["'])(.*?)\1/is)        { $desc = $2; }
    elsif ($html =~ /<meta\s+content=(["'])(.*?)\1\s+name=["']description["']/is)        { $desc = $2; }
    if (defined $desc) {
        $desc = _decode_html($desc);
        for my $seg (split /\s*[·•]\s*/, $desc) {
            $seg =~ s/^\s+|\s+$//g;
            next if $seg eq '';
            if    ($seg =~ /^(Album|Single|EP|Song|Playlist)$/i)      { $am{type}   //= lc $1; }
            elsif ($seg =~ /^\s*((?:19|20)\d{2})\s*$/)                 { $am{year}   //= $1; }
            elsif ($seg =~ /^(\d+)\s+Songs?$/i)                        { $am{tracks} //= $1; }
        }
    }
    return \%am;
}

sub _applemusic_lookup_track {
    my ($self, $http, $storefront, $track_id) = @_;
    return undef unless defined $track_id && $track_id =~ /^\d+$/;

    my $lookup = 'https://itunes.apple.com/lookup?id=' . $track_id
               . '&country=' . uri_escape_utf8(uc($storefront // 'us'))
               . '&entity=song';

    my $res = eval { $http->get($lookup); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    unless ($res->{success}) {
        $self->{logger}->log(4,
            "_handle_applemusic() lookup HTTP $res->{status} $res->{reason} for track=$track_id");
        return undef;
    }

    my $data = eval { decode_json($res->{content} // '') };
    unless (ref($data) eq 'HASH') {
        my $error = $@ || 'not a JSON object';
        $error =~ s/\s+/ /g;
        $self->{logger}->log(4,
            "_handle_applemusic() lookup JSON decode failed for track=$track_id: $error");
        return undef;
    }

    my $results = ref($data->{results}) eq 'ARRAY' ? $data->{results} : [];
    my ($r) = grep {
        ref($_) eq 'HASH'
            && defined($_->{trackId})
            && "$_->{trackId}" eq "$track_id"
            && (!defined($_->{kind}) || $_->{kind} eq 'song')
    } @$results;

    return undef unless ref($r) eq 'HASH';

    my %am = (type => 'song');
    $am{artist} = $r->{artistName}
        if defined $r->{artistName} && $r->{artistName} ne '';
    $am{album} = $r->{collectionName}
        if defined $r->{collectionName} && $r->{collectionName} ne '';
    $am{year} = $1
        if defined($r->{releaseDate}) && $r->{releaseDate} =~ /^((?:19|20)\d{2})/;
    $am{duration} = _am_duration_from_ms($r->{trackTimeMillis})
        if defined $r->{trackTimeMillis};

    my $title = $r->{trackName};
    return undef unless defined $title && $title ne '';

    return {
        title   => $title,
        details => \%am,
        source  => 'itunes-lookup',
        status  => int($res->{status} // 200),
        bytes   => length($res->{content} // ''),
    };
}

sub _applemusic_fetch_sync {
    my ($self, $url) = @_;

    my $info = _applemusic_url_info($url);
    my $http = Mediabot::External::_make_http(
        timeout  => 12,
        max_size => 512 * 1024,
    );

    if (defined $info->{track_id}) {
        my $track = _applemusic_lookup_track(
            $self, $http, $info->{storefront}, $info->{track_id}
        );
        return $track if ref($track) eq 'HASH';
    }

    my $title;
    my $html_for_details = '';
    my $res = eval { $http->get($url); } // {
        success => 0,
        status  => 0,
        reason  => $@,
    };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8(
            $self, $res->{content} // '', 'applemusic-http'
        );
        $html_for_details = $content;

        my ($og_title, $meta_description, $title_tag);

        if ($content =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
            $og_title = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
            $og_title = $1;
        }

        if ($content =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
            $meta_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
            $meta_description = $1;
        }

        if ($content =~ /<title[^>]*>([^<]+)<\/title>/i) {
            $title_tag = $1;
            $title_tag =~ s/\s*[–-]\s*Apple Music\s*$//i;
        }

        for ($og_title, $meta_description, $title_tag) {
            $_ = _decode_html($_) if defined $_;
        }

        for my $candidate ($og_title, $meta_description, $title_tag) {
            next unless defined $candidate && $candidate ne '';
            next if $candidate =~ /^\s*Apple Music\s*$/i;
            next if $candidate =~ /listen on apple music/i;
            next if $candidate =~ /open in music/i;
            $title = $candidate;
            last;
        }
    }
    else {
        $self->{logger}->log(3,
            "_handle_applemusic() HTTP $res->{status} $res->{reason} for $url");
    }

    my $title_check = defined($title) ? $title : '';
    $title_check =~ s/\s+/ /g;
    $title_check =~ s/^\s+|\s+$//g;

    if (!defined($title) || $title_check eq '' || $title_check =~ /^\s*Apple Music\s*$/i) {
        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $url,
            virtual_time_budget => 10000,
            alarm_timeout       => 30,
        );

        if (defined $dom && $dom ne '') {
            $html_for_details = $dom;
            my ($og_title, $meta_description, $title_tag);

            if ($dom =~ /<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']/i) {
                $og_title = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:title["']/i) {
                $og_title = $1;
            }

            if ($dom =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
                $meta_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
                $meta_description = $1;
            }

            if ($dom =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $title_tag = $1;
                $title_tag =~ s/\s*[–-]\s*Apple Music\s*$//i;
            }

            for ($og_title, $meta_description, $title_tag) {
                $_ = _decode_html($_) if defined $_;
            }

            for my $candidate ($og_title, $meta_description, $title_tag) {
                next unless defined $candidate && $candidate ne '';
                next if $candidate =~ /^\s*Apple Music\s*$/i;
                next if $candidate =~ /listen on apple music/i;
                next if $candidate =~ /open in music/i;
                $title = $candidate;
                last;
            }
        }
    }

    return {
        title   => $title,
        details => _applemusic_extract_details($self, $html_for_details),
        source  => 'page-fallback',
        status  => int($res->{status} // 0),
        bytes   => length($html_for_details),
    };
}

sub _handle_applemusic {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_applemusic() start url=$url");

    my $info = _applemusic_url_info($url);
    my $cache_key = defined($info->{track_id})
        ? join(':', 'track', $info->{storefront}, $info->{track_id})
        : lc($url // '');

    my $cached = $self->{_applemusic_cache}{$cache_key};
    if ($cached && (time() - ($cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_applemusic() cache hit for $url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $cached->{msg}");
        return 1;
    }

    my $finish = sub {
        my ($fetch, $worker_status) = @_;
        delete $self->{_applemusic_pending}{$cache_key};

        $fetch = {} unless ref($fetch) eq 'HASH';
        my $title = $fetch->{title};
        my $am = ref($fetch->{details}) eq 'HASH' ? $fetch->{details} : {};

        unless (defined $title && $title ne '') {
            $self->{logger}->log(3,
                "_handle_applemusic() could not extract title from $url worker="
                . (defined($worker_status) ? $worker_status : 'sync'));
            return undef;
        }

        $title =~ s/\s+/ /g;
        $title =~ s/^\s+|\s+$//g;

        my @parts = ($title);
        if (defined $am->{artist} && $am->{artist} ne ''
            && lc($am->{artist}) ne lc($title)
            && index(lc($title), lc($am->{artist})) < 0) {
            push @parts, "by $am->{artist}";
        }
        if (defined $am->{album} && $am->{album} ne ''
            && lc($am->{album}) ne lc($title)) {
            push @parts, "album $am->{album}";
        }
        push @parts, $am->{type}
            if defined $am->{type} && $am->{type} ne '' && lc($am->{type}) ne 'song';
        push @parts, $am->{year} if defined $am->{year};
        push @parts, $am->{duration} if defined $am->{duration};
        push @parts, "$am->{tracks} tracks"
            if defined $am->{tracks} && $am->{tracks} =~ /^\d+$/ && $am->{tracks} > 1;

        my $display = join(' - ', @parts);
        $display =~ s/\s+/ /g;
        $display =~ s/^\s+|\s+$//g;
        $display = Mediabot::Helpers::truncate_utf8($display, 300, '…');

        $self->{logger}->log(4,
            "_handle_applemusic() final display='$display' source=" . ($fetch->{source} // 'unknown'));

        my $badge = String::IRC->new("[")->white('black');
        $badge   .= String::IRC->new("\x{2318}Music")->white('grey');
        $badge   .= String::IRC->new("]")->white('black');
        my $msg = "$badge\x0f $display";

        $self->{_applemusic_cache}{$cache_key} = { ts => time(), msg => $msg };
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
        return 1;
    };

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    if ($loop
        && eval { $loop->can('add') }
        && eval { $loop->can('remove') }
        && eval { $loop->can('watch_process') }) {

        if ($self->{_applemusic_pending}{$cache_key}) {
            $self->{logger}->log(4,
                "_handle_applemusic() request already pending for $url");
            return 1;
        }
        $self->{_applemusic_pending}{$cache_key} = time();

        my $adapter_done = 0;
        my $done = sub {
            my ($result) = @_;
            return if $adapter_done++;

            my $fetch = {};
            my $worker_status = 'failed';
            if (ref($result) eq 'HASH' && $result->{ok}) {
                $fetch = ref($result->{value}) eq 'HASH' ? $result->{value} : {};
                $worker_status = 'ok';
            }
            elsif (ref($result) eq 'HASH') {
                $worker_status = $result->{error} // 'failed';
            }

            eval { $finish->($fetch, $worker_status); 1 } or do {
                my $error = $@ || 'unknown Apple Music completion error';
                $error =~ s/\s+/ /g;
                delete $self->{_applemusic_pending}{$cache_key};
                $self->{logger}->log(1,
                    "_handle_applemusic() completion failed: $error");
            };
        };

        my $worker;
        my $launch_ok = eval {
            $worker = Mediabot::AsyncWorker->start(
                loop        => $loop,
                label       => 'apple music metadata',
                timeout     => 45,
                term_grace  => 0.2,
                force_grace => 1.0,
                max_output  => 16 * 1024,
                child       => sub { return _applemusic_fetch_sync($self, $url); },
                on_done     => $done,
            );
            1;
        };

        if (!$launch_ok && !$adapter_done) {
            my $error = $@ || 'AsyncWorker launch failed';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(2,
                "_handle_applemusic() async launch failed: $error");
            $done->({ ok => 0, error => 'worker_setup' });
        }
        elsif (!$worker && !$adapter_done) {
            $done->({ ok => 0, error => 'worker_setup' });
        }

        return 1;
    }

    return $finish->(_applemusic_fetch_sync($self, $url), 'sync-no-loop');
}

# ---------------------------------------------------------------------------
# _facebook_url($url)
# Normalize Facebook root URLs so they behave like browser/curl -L tests.
# ---------------------------------------------------------------------------
sub _facebook_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?facebook\.com(?:/|$)}i;

    $url =~ s{^http://}{https://}i;
    $url =~ s{^https://facebook\.com/?}{https://www.facebook.com/}i;

    return $url;
}

# ---------------------------------------------------------------------------
# _facebook_title_from_html($self, $html, $context)
# Extract a usable Facebook title from HTML/DOM.
# ---------------------------------------------------------------------------
sub _facebook_title_from_html {
    my ($self, $html, $context) = @_;

    return undef unless defined $html && $html ne '';

    my $title;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /property=["']og:title["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $title = $1;
            last;
        }
    }

    if (!defined($title) && $html =~ /<title[^>]*>(.*?)<\/title>/si) {
        $title = $1;
    }

    return undef unless defined $title && $title ne '';

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\x{a0}/ /g;   # mb495: nbsp from decoded counters -> plain space
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    # mb495: reel og:title = "<view/reaction counters, random locale> | <caption>"
    # (e.g. "377 K views · 2.6 K reactions | Would you be so kind..."). When the
    # title STARTS with a digit and carries a pipe, keep the caption side.
    if ($title =~ /^\s*\d/ && $title =~ /^[^|]{1,120}\|\s*(\S.*)$/s) {
        $title = $1;
        $title =~ s/\s{2,}/ /g;
        $title =~ s/^\s+|\s+$//g;
    }

    return undef if $title eq '';
    return undef if $title =~ /^\s*Facebook\s*$/i;
    return undef if $title =~ /^(?:Log in|Se connecter|Connexion|Sign up|Inscription)\s*(?:to|à|sur)?\s*Facebook/i;
    return undef if $title =~ /(?:log in|se connecter).*(?:Facebook)/i && length($title) < 80;

    $self->{logger}->log(4, "_facebook_title_from_html() $context selected title='$title'");

    return $title;
}

# ---------------------------------------------------------------------------
# _facebook_fallback_title_from_url($url)
# Last-resort label for Facebook URLs when both HTTP and Chromium only expose
# a login shell or unusable generic title.
# ---------------------------------------------------------------------------
sub _facebook_fallback_title_from_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?facebook\.com(?:/|$)}i;

    my $normalized = $url;
    $normalized =~ s{^http://}{https://}i;
    $normalized =~ s{^https://facebook\.com/?}{https://www.facebook.com/}i;

    return 'Facebook' if $normalized =~ m{^https://www\.facebook\.com/?(?:[?#].*)?\z}i;

    my $path = $normalized;
    $path =~ s{^https://www\.facebook\.com/?}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};

    return 'Facebook link' if $path eq '';

    $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

    my @parts = grep { defined $_ && $_ ne '' } split m{/+}, $path;

    my $clean = sub {
        my ($s) = @_;

        return '' unless defined $s;

        $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $s =~ s/[._-]+/ /g;
        $s =~ s/\s{2,}/ /g;
        $s =~ s/^\s+|\s+\z//g;

        return $s;
    };

    return 'Facebook reel'  if $path =~ m{^(?:reel|reels)/}i;
    return 'Facebook video' if $path =~ m{^(?:watch|videos?)(?:/|\z)}i;
    return 'Facebook photo' if $path =~ m{^(?:photo\.php|photo/|photos?)(?:/|\z)}i;
    return 'Facebook story' if $path =~ m{^(?:stories|story\.php)(?:/|\z)}i;
    return 'Facebook event' if $path =~ m{^events?/}i;

    if (@parts >= 4 && lc($parts[0]) eq 'groups' && lc($parts[2]) eq 'posts') {
        my $group = $clean->($parts[1]);
        return $group ne '' ? "Facebook group post: $group" : 'Facebook group post';
    }

    if (@parts >= 2 && lc($parts[0]) eq 'groups') {
        my $group = $clean->($parts[1]);
        return $group ne '' ? "Facebook group: $group" : 'Facebook group';
    }

    if (@parts >= 3 && lc($parts[1]) eq 'posts') {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "Facebook post by $owner" : 'Facebook post';
    }

    if (@parts >= 3 && lc($parts[1]) =~ /^videos?$/) {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "Facebook video by $owner" : 'Facebook video';
    }

    if (@parts >= 1) {
        my $owner = $clean->($parts[0]);

        return 'Facebook link'
            if $owner eq ''
            || $owner =~ /^(?:permalink\.php|profile\.php|share|sharer|login|recover|help|marketplace)$/i;

        return "Facebook: $owner";
    }

    return 'Facebook link';
}

# ---------------------------------------------------------------------------
# _handle_facebook($self, $message, $nick, $channel, $url)
# Facebook often behaves differently than generic sites.  Keep it out of the
# generic title path and use a dedicated HTTP + Chromium fallback.
# ---------------------------------------------------------------------------
sub _handle_facebook {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $fb_html = '';   # mb492: html we ended up trusting

    my $fb_url = _facebook_url($url);
    unless (defined $fb_url) {
        $self->{logger}->log(4, "_handle_facebook() not a supported Facebook URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_facebook() start url=$fb_url");

    # IMP10: serve from cache if fresh (TTL 10 min)
    my $fb_cached = $self->{_facebook_cache}{lc($fb_url)};
    if ($fb_cached && (time() - ($fb_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_facebook() cache hit for $fb_url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $fb_cached->{msg}");
        return 1;
    }

    my $title;

    # Step 1: cheap HTTP fetch.  On your server, HTTP::Tiny follows
    # facebook.com -> www.facebook.com and can receive a normal 200 page.
    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
        agent    => 'facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)',   # mb494: social-crawler UA -> server-side og: tags
        default_headers => { 'accept-language' => 'en-US,en;q=0.8' },   # mb495: stable counter locale
    );

    my $res = eval { $http->get($fb_url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'facebook-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_facebook() HTTP fetched $len bytes for $fb_url");
        $fb_html = $content;   # mb492
        $title = _facebook_title_from_html($self, $content, 'HTTP');
    }
    else {
        $self->{logger}->log(4, "_handle_facebook() HTTP $res->{status} $res->{reason} for $fb_url");
    }

    # Step 2: Chromium fallback.  Keep it for non-Reel Facebook URLs where
    # rendered metadata can still add value. Public Reel shells are different:
    # when the crawler HTML has no usable title, Chromium commonly waits until
    # its alarm and still exposes no metadata. Skip that known-dead path so the
    # deterministic Reel fallback is returned immediately.
    unless (defined $title && $title ne '') {
        my $is_reel = $fb_url =~ m{^https://www\.facebook\.com/(?:reel|reels)/}i ? 1 : 0;

        if ($is_reel) {
            $self->{logger}->log(4, "_handle_facebook() Reel shell has no usable HTTP metadata; skipping Chromium");
        }
        else {
            $self->{logger}->log(4, "_handle_facebook() falling back to Chromium rendered DOM");

            my $fb_vtb = int(eval { $self->{conf}->get('chromium.FACEBOOK_VIRTUAL_TIME_BUDGET') } // 6500);
            my $fb_alarm = int(eval { $self->{conf}->get('chromium.FACEBOOK_ALARM_TIMEOUT') } // 22);

            $fb_vtb = 1000 if $fb_vtb < 1000;
            $fb_vtb = 30000 if $fb_vtb > 30000;
            $fb_alarm = 5 if $fb_alarm < 5;
            $fb_alarm = 60 if $fb_alarm > 60;

            my $dom = _fetch_url_chromium_dumpdom(
                $self,
                $fb_url,
                virtual_time_budget => $fb_vtb,
                alarm_timeout       => $fb_alarm,
                lang                => 'fr-FR',
            );

            if (defined $dom && $dom ne '') {
                my $len = length($dom);
                $self->{logger}->log(4, "_handle_facebook() Chromium DOM fetched $len bytes for $fb_url");
                $fb_html = $dom;   # mb492
                $title = _facebook_title_from_html($self, $dom, 'Chromium');
            }
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = _facebook_fallback_title_from_url($fb_url);
        if (defined $fallback_title && $fallback_title ne '') {
            $title = $fallback_title;
            $self->{logger}->log(4, "_handle_facebook() using URL fallback title '$title' for $fb_url");
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_facebook() no usable title extracted for $fb_url");
        return undef;
    }

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Facebook")->white('blue');
    $badge   .= String::IRC->new("]")->white('black');

    # mb492: append og:description when informative and not a duplicate
    my $fb_line = $title;
    my $fb_desc;
    if    ($fb_html =~ /<meta\s+property=["']og:description["']\s+content=(["'])(.*?)\1/is) { $fb_desc = $2; }
    elsif ($fb_html =~ /<meta\s+content=(["'])(.*?)\1\s+property=["']og:description["']/is) { $fb_desc = $2; }
    if (defined $fb_desc) {
        $fb_desc = _decode_html($fb_desc);
        $fb_desc =~ s/[\r\n\t]/ /g; $fb_desc =~ s/\s{2,}/ /g; $fb_desc =~ s/^\s+|\s+$//g;
        if ($fb_desc ne ''
            && $fb_desc !~ /^(?:Log in|Se connecter|Sign in|Connexion)/i
            && $fb_desc !~ /facebook/i
            && index(lc($fb_line), lc(substr($fb_desc, 0, 40))) < 0) {
            my $d = length($fb_desc) > 150 ? substr($fb_desc, 0, 147) . '...' : $fb_desc;
            $fb_line .= " - $d";
        }
    }

    my $msg = "$badge\x0f " . substr($fb_line, 0, 300);
    # IMP10: cache the result (TTL 10 min) to avoid redundant Chromium fetches
    $self->{_facebook_cache}{lc($fb_url)} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _x_url($url)
# Normalize X/Twitter URLs so the dedicated handler has one canonical shape.
# ---------------------------------------------------------------------------
sub _x_url {
    my ($url) = @_;

    return undef unless defined $url && $url =~ m{^https?://(?:www\.)?(?:x|twitter)\.com(?:/|$)}i;

    $url =~ s{^http://}{https://}i;
    $url =~ s{^https://(?:www\.)?twitter\.com(?=/|$)}{https://x.com}i;
    $url =~ s{^https://www\.x\.com(?=/|$)}{https://x.com}i;
    $url =~ s{^https://x\.com/?}{https://x.com/}i;

    $url .= '/' if $url =~ m{^https://x\.com\z}i;

    return $url;
}

# ---------------------------------------------------------------------------
# _x_title_from_html($self, $html, $context)
# Extract a usable X/Twitter title from rendered DOM or HTML.
# ---------------------------------------------------------------------------
sub _x_title_from_html {
    my ($self, $html, $context) = @_;

    return undef unless defined $html && $html ne '';

    my $title;

    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /(?:property|name)=["'](?:og:title|twitter:title)["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            $title = $1;
            last;
        }
    }

    if (!defined($title) && $html =~ /<title[^>]*>(.*?)<\/title>/si) {
        $title = $1;
    }

    return undef unless defined $title && $title ne '';

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    return undef if $title eq '';
    return undef if $title =~ /^(?:X|Twitter)$/i;
    return undef if $title =~ /^(?:Log in|Se connecter|Sign in|Connexion)\s*(?:to|à|sur)?\s*(?:X|Twitter)/i;
    return undef if $title =~ /(?:JavaScript is not available|This browser is no longer supported)/i;

    $self->{logger}->log(4, "_x_title_from_html() $context selected title='$title'");

    return $title;
}

# ---------------------------------------------------------------------------
# _x_fallback_title_from_url($url)
# Last-resort honest label when X only exposes a login shell.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _x_desc_from_html($self, $html, $context)
# mb492: pull the tweet text (og:description / twitter:description) with the
# same anti-login-shell guards as the title. Returns undef when unusable.
# ---------------------------------------------------------------------------
sub _x_desc_from_html {
    my ($self, $html, $context) = @_;
    return undef unless defined $html && $html ne '';

    my $desc;
    while ($html =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;
        next unless $attrs =~ /(?:property|name)=["'](?:og:description|twitter:description)["']/i;
        # mb492: paired-quote capture so apostrophes don't truncate the tweet
        if ($attrs =~ /\bcontent=(["'])(.*?)\1/is) { $desc = $2; last; }
    }
    return undef unless defined $desc && $desc ne '';

    $desc = _decode_html($desc);
    $desc =~ s/[\r\n\t]/ /g;
    $desc =~ s/\s{2,}/ /g;
    $desc =~ s/^\s+|\s+$//g;
    # strip X's decorative curly quotes wrapping the tweet text
    $desc =~ s/^[\x{201C}"]//; $desc =~ s/[\x{201D}"]$//;

    return undef if $desc eq '';
    return undef if $desc =~ /^(?:X|Twitter)$/i;
    return undef if $desc =~ /(?:JavaScript is not available|This browser is no longer supported)/i;
    return undef if $desc =~ /^(?:Log in|Se connecter|Sign in|Connexion)/i;

    $self->{logger}->log(4, "_x_desc_from_html() $context selected desc len=" . length($desc));
    return $desc;
}

# ---------------------------------------------------------------------------
# _x_compact_count($n) — mb494: 950 -> "950", 12345 -> "12.3k", 4200000 -> "4.2M"
# ---------------------------------------------------------------------------
sub _x_compact_count {
    my ($n) = @_;
    return '0' unless defined $n && $n =~ /^\d+$/;
    return "$n" if $n < 1000;
    # mb496 fix: 999999 rounded to "1000.0k" -> promote to M at the boundary
    if ($n < 1_000_000) {
        my $s = sprintf('%.1f', $n / 1000);
        return ($s =~ s/\.0$//r) . 'k' if $s ne '1000.0';
    }
    my $m = sprintf('%.1f', $n / 1_000_000);
    return ($m =~ s/\.0$//r) . 'M';
}

sub _x_fallback_title_from_url {
    my ($url) = @_;

    my $x_url = _x_url($url);
    return undef unless defined $x_url;

    return 'X' if $x_url =~ m{^https://x\.com/?(?:[?#].*)?\z}i;

    my $path = $x_url;
    $path =~ s{^https://x\.com/?}{}i;
    $path =~ s/[?#].*\z//;
    $path =~ s{/+\z}{};

    return 'X link' if $path eq '';

    $path =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

    my @parts = grep { defined $_ && $_ ne '' } split m{/+}, $path;

    my $clean = sub {
        my ($s) = @_;

        return '' unless defined $s;

        $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;
        $s =~ s/[._-]+/ /g;
        $s =~ s/\s{2,}/ /g;
        $s =~ s/^\s+|\s+\z//g;

        return $s;
    };

    if (@parts >= 3 && lc($parts[0]) eq 'i' && lc($parts[1]) eq 'web' && lc($parts[2]) eq 'status') {
        return 'X post';
    }

    if (@parts >= 3 && lc($parts[1]) =~ /^status(?:es)?$/) {
        my $owner = $clean->($parts[0]);
        return $owner ne '' ? "X post by \@$owner" : 'X post';
    }

    if (@parts >= 3 && lc($parts[1]) eq 'lists') {
        my $owner = $clean->($parts[0]);
        my $list  = $clean->($parts[2]);

        return "X list by \@$owner: $list" if $owner ne '' && $list ne '';
        return "X list by \@$owner"       if $owner ne '';
        return 'X list';
    }

    if (@parts >= 2 && lc($parts[0]) eq 'i' && lc($parts[1]) eq 'communities') {
        return 'X community';
    }

    if (@parts >= 1) {
        my $owner = $clean->($parts[0]);

        return 'X link'
            if $owner eq ''
            || $owner =~ /^(?:home|explore|search|notifications|messages|i|intent|share|login|logout|settings)$/i;

        return "X profile: \@$owner";
    }

    return 'X link';
}

# ---------------------------------------------------------------------------
# _handle_x_twitter($self, $message, $nick, $channel, $url)
# X/Twitter is not a generic website for URL titles.  It often needs a rendered
# DOM to expose useful metadata, and it may still only show a login shell.
# ---------------------------------------------------------------------------
sub _handle_x_twitter {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $x_url = _x_url($url);
    unless (defined $x_url) {
        $self->{logger}->log(4, "_handle_x_twitter() not a supported X/Twitter URL: " . ($url // '<undef>'));
        return undef;
    }

    $self->{logger}->log(4, "_handle_x_twitter() start url=$x_url");

    # IMP10: cache x_twitter result (TTL 10 min) — Chromium is expensive
    my $tw_cache     = $self->{_x_twitter_cache} //= {};
    my $tw_cache_key = lc($url);
    my $tw_now       = time();
    if (my $cached = $tw_cache->{$tw_cache_key}) {
        if ($tw_now - ($cached->{ts} // 0) < 600) {
            $self->{logger}->log(4, "_handle_x_twitter() serving from cache: $url");

            # IMP10/fix: replay the cached IRC message.
            # Older mb76 code cached only result => 1, which made cache hits silent.
            if (defined($cached->{msg}) && $cached->{msg} ne '') {
                Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $cached->{msg}");
                return 1;
            }

            # Backward-compatible cleanup for any stale in-memory entries created
            # by the old code during the same process lifetime.
            delete $tw_cache->{$tw_cache_key};
        }
        else {
            delete $tw_cache->{$tw_cache_key};
        }
    }

    my $title;
    my $tweet_text;
    my ($fx_likes, $fx_rts);

    # mb494: FAST PATH — public fxtwitter JSON API (~300 ms), the way fast
    # bots answer in under a second. Chromium only runs if this misses.
    if ($x_url =~ m{^https://x\.com/([^/]+)/status/(\d+)}i) {
        my ($screen, $tid) = ($1, $2);
        my $api  = "https://api.fxtwitter.com/$screen/status/$tid";
        my $http = Mediabot::External::_make_http(timeout => 6, max_size => 512 * 1024);
        my $t0   = Time::HiRes::time();
        my $res  = eval { $http->get($api) } // { success => 0, status => 0, reason => "die: $@" };
        my $dt   = sprintf('%.2f', Time::HiRes::time() - $t0);
        if ($res->{success}) {
            my $data = eval { decode_json($res->{content} // '') };
            if (ref($data) eq 'HASH' && ($data->{code} // 0) == 200 && ref($data->{tweet}) eq 'HASH') {
                my $tw      = $data->{tweet};
                my $name    = eval { $tw->{author}{name} }        // '';
                my $screen2 = eval { $tw->{author}{screen_name} } // $screen;
                # mb496: guard against unexpected non-scalar API shapes
                $name    = '' if ref $name;
                $screen2 = $screen if ref $screen2;
                $title      = $name ne '' ? "$name (\@$screen2) on X" : "\@$screen2 on X";
                $tweet_text = (defined $tw->{text}  && !ref $tw->{text})  ? $tw->{text}  : undef;
                $fx_likes   = (defined $tw->{likes} && !ref $tw->{likes}) ? $tw->{likes} : undef;
                $fx_rts     = (defined $tw->{retweets} && !ref $tw->{retweets}) ? $tw->{retweets} : undef;
                $self->{logger}->log(4, "_handle_x_twitter() fxtwitter hit in ${dt}s for $x_url");
            }
            else {
                $self->{logger}->log(4, "_handle_x_twitter() fxtwitter unusable JSON (code="
                    . (ref($data) eq 'HASH' ? ($data->{code} // '?') : '?') . ") in ${dt}s for $x_url");
            }
        }
        else {
            $self->{logger}->log(4, "_handle_x_twitter() fxtwitter HTTP "
                . ($res->{status} // '?') . " in ${dt}s for $x_url");
        }
    }

    # X is rendered/client-heavy.  Go through Chromium ONLY when the fast
    # path above did not deliver (profiles, or fxtwitter outage).
    # XT1/fix: eval around chromium call — external process may die/timeout
    my $dom;
    unless (defined $title && $title ne '') {
        $dom = eval { _fetch_url_chromium_dumpdom(
            $self,
            $x_url,
            virtual_time_budget => 6500,
            alarm_timeout       => 16,
            lang                => 'fr-FR',
        ) };
        if ($@) {
            $self->{logger}->log(1, "_handle_x_twitter() chromium error: $@");
            return undef;
        }

        if (defined $dom && $dom ne '') {
            my $len = length($dom);
            $self->{logger}->log(4, "_handle_x_twitter() Chromium DOM fetched $len bytes for $x_url");
            $title = _x_title_from_html($self, $dom, 'Chromium');
            $tweet_text = _x_desc_from_html($self, $dom, 'Chromium');
        }
        else {
            $self->{logger}->log(4, "_handle_x_twitter() Chromium returned no usable DOM for $x_url");
        }
    }

    unless (defined $title && $title ne '') {
        my $fallback_title = _x_fallback_title_from_url($x_url);
        if (defined $fallback_title && $fallback_title ne '') {
            $title = $fallback_title;
            $self->{logger}->log(4, "_handle_x_twitter() using URL fallback title '$title' for $x_url");
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_x_twitter() no usable title extracted for $x_url");
        return undef;
    }

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("X")->white('black');
    $badge   .= String::IRC->new("]")->white('black');

    # mb492: append the tweet text when we have it and the title doesn't
    # already carry it (X og:title is often just 'Nick on X').
    my $line = $title;
    if (defined $tweet_text && $tweet_text ne '') {
        my $probe = substr($tweet_text, 0, 40);
        if (index(lc($line), lc($probe)) < 0) {
            my $t = length($tweet_text) > 200 ? substr($tweet_text, 0, 197) . '...' : $tweet_text;
            $t =~ s/[\r\n]+/ /g;
            $line .= qq{: "$t"};
        }
    }
    # mb494: engagement stats from the fxtwitter fast path
    if ((defined $fx_likes && $fx_likes =~ /^\d+$/ && $fx_likes > 0)
        || (defined $fx_rts && $fx_rts =~ /^\d+$/ && $fx_rts > 0)) {
        my @st;
        push @st, _x_compact_count($fx_likes) . ' likes' if defined $fx_likes && $fx_likes > 0;
        push @st, _x_compact_count($fx_rts)   . ' RTs'   if defined $fx_rts   && $fx_rts > 0;
        $line .= ' (' . join(', ', @st) . ')' if @st;
    }

    my $msg = "$badge\x0f " . substr($line, 0, 300);

    # IMP10/fix: cache the formatted message, not just a boolean.
    # That way repeated X/Twitter URLs avoid Chromium but still produce the same
    # user-visible IRC output when the generic URL anti-repeat cache allows it.
    $tw_cache->{$tw_cache_key} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
}

# ---------------------------------------------------------------------------
# _clean_generic_url_title($title)
# Normalize and reject useless generic browser/security/error titles.
# ---------------------------------------------------------------------------
sub _clean_generic_url_title {
    my ($title) = @_;

    return undef unless defined $title;

    $title = _decode_html($title);
    $title =~ s/[\r\n\t]/ /g;
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

    return undef if $title eq '';

    # Browser / anti-bot / CDN / error shells. They are technically titles,
    # but they are useless in an IRC UrlTitle response.
    # A4: centralised list of bot-wall / error page patterns — easy to extend
    my @_BLOCKED_TITLE_PATTERNS = (
        qr/^\s*Just a moment\.{0,3}\s*$/i,
        qr/^\s*Attention Required!\s*\|\s*Cloudflare\s*$/i,
        qr/^\s*Access Denied\s*$/i,
        qr/^\s*403 Forbidden\s*$/i,
        qr/^\s*404 Not Found\s*$/i,
        qr/^\s*Page Not Found\s*$/i,
        qr/^\s*Not Found\s*$/i,
        qr/^\s*Error\s*$/i,
        qr/please enable javascript/i,
        qr/javascript is not available/i,
        qr/checking your browser/i,
        qr/one moment, please/i,
        qr/robot check/i,
        qr/verify you are human/i,
    );
    return undef if grep { $title =~ $_ } @_BLOCKED_TITLE_PATTERNS;

    # mb408-R1: troncature à la frontière de mot + ellipse. Avant,
    # substr(0,300) coupait en plein mot sans indiquer la coupe.
    if (length($title) > 300) {
        $title = substr($title, 0, 300);
        $title =~ s/\s+\S*$// if $title =~ /\s/;   # ne pas finir sur un mot coupé
        $title .= '…';
    }

    return $title;
}

# ---------------------------------------------------------------------------
# _handle_generic_title($self, $message, $nick, $channel, $url)
# Generic URL: fetch page, extract <title>. No HTML::Tree — regex is enough.
# ---------------------------------------------------------------------------
sub _handle_generic_title {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 768 * 1024,
    );

    my $res  = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };
    unless ($res->{success}) {
        $self->{logger}->log(3, "_handle_generic_title() HTTP $res->{status} $res->{reason} for $url");
        return undef;
    }

    my $content_type = '';
    if (ref($res->{headers}) eq 'HASH') {
        $content_type = $res->{headers}->{'content-type'} // $res->{headers}->{'Content-Type'} // '';
    }

    if ($content_type ne ''
        && $content_type !~ m{text/html|application/xhtml\+xml|application/xml|text/xml}i
    ) {
        $self->{logger}->log(4, "_handle_generic_title() skipped non-HTML content-type '$content_type' for $url");
        return undef;
    }

    my $content = _decode_http_content_utf8($self, $res->{content} // '', 'generic');
    my @candidates;

    # Prefer explicit social metadata when available.
    while ($content =~ /<meta\b([^>]*?)>/sig) {
        my $attrs = $1;

        next unless $attrs =~ /(?:property|name)=["'](?:og:title|twitter:title)["']/i;

        if ($attrs =~ /\bcontent=["']([^"']+)["']/i) {
            push @candidates, $1;
        }
    }

    if ($content =~ /<title[^>]*>(.*?)<\/title>/si) {
        push @candidates, $1;
    }

    unless (@candidates) {
        $self->{logger}->log(4, "_handle_generic_title() no title candidate found for $url");
        return undef;
    }

    my $title;
    for my $candidate (@candidates) {
        my $clean = _clean_generic_url_title($candidate);
        next unless defined $clean && $clean ne '';

        $title = $clean;
        last;
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_generic_title() only useless/generic title candidates found for $url");
        return undef;
    }

    # Keep historical label style, but hard-reset before the displayed title.
    # Y4: include domain in badge for context
    my $domain = '';
    if ($url =~ m{^https?://([^/?#]+)}i) {
        $domain = $1;
        $domain =~ s/^www\.//i;
        $domain = substr($domain, 0, 30);  # cap length
    }
    my $label = String::IRC->new("URL")->grey('black');
    $label   .= String::IRC->new(" $domain")->white('black') if $domain;
    $label   .= String::IRC->new(" $nick:")->grey('black');
    Mediabot::Helpers::botPrivmsg($self, $channel, "$label\x0f $title");
    return 1;
}

# ---------------------------------------------------------------------------
# _url_display_cache_gate($self, $url, $channel)
#
# Anti-repeat cache for displayed URLs.  The caller invokes this only after the
# matching chanset has accepted the URL, so disabled features never burn an URL
# that should become immediately usable after being enabled.
# ---------------------------------------------------------------------------
sub _url_display_cache_gate {
    my ($self, $url, $channel) = @_;

    my $cache_key = lc($url // '') . "\x00" . lc($channel // '');
    my $cache     = $self->{_url_display_cache} //= {};
    my $now       = time();
    my $url_ttl   = 300;  # 5 minutes

    # Purge stale entries at most once per minute.
    if (($self->{_url_cache_last_purge} // 0) < $now - 60) {
        my @stale = grep { ($cache->{$_} // 0) < $now - $url_ttl } keys %$cache;
        delete @{$cache}{@stale};
        $self->{_url_cache_last_purge} = $now;
    }

    if (($cache->{$cache_key} // 0) >= $now - $url_ttl) {
        $self->{logger}->log(4, "displayUrlTitle() skipping repeated URL: $url");
        return 0;
    }

    $cache->{$cache_key} = $now;
    return 1;
}

# ---------------------------------------------------------------------------
# displayUrlTitle($self, $message, $nick, $channel, $text)
#
# Main entry point for URL handling from on_message_PRIVMSG.
# Handles all URL types: YouTube, Instagram, Spotify, Apple Music, generic.
# Chanset guards are checked here (not in mediabot.pl).
# ---------------------------------------------------------------------------
sub displayUrlTitle {
    my ($self, $message, $sNick, $sChannel, $sText) = @_;

    $self->{logger}->log(4, "displayUrlTitle() RAW input: $sText");

    my $url = _extract_url($sText);
    my $captured_url = $url // '(unknown)';  # DU1/fix: capture before eval scope

    my $result = eval {
    
        unless (defined $url && $url =~ /^https?:\/\//i) {
            $self->{logger}->log(4, "displayUrlTitle() no valid URL found in: $sText");
            return undef;
        }

        # IMP2/polish: skip obvious private/internal literal hosts before any
        # network fetch. This is a lightweight guard, not a full SSRF firewall:
        # it intentionally avoids DNS resolution here.
        if ($url =~ m{^https?://
                (?:
                    localhost(?:[/:]|\z)
                  | 0\.0\.0\.0(?:[/:]|\z)
                  | 127\.\d+\.\d+\.\d+(?:[/:]|\z)
                  | 10\.\d+\.\d+\.\d+(?:[/:]|\z)
                  | 172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+(?:[/:]|\z)
                  | 192\.168\.\d+\.\d+(?:[/:]|\z)
                  | 169\.254\.\d+\.\d+(?:[/:]|\z)
                  | \[(?: ::1
                       | fc[0-9a-f]{2}:[0-9a-f:]+
                       | fd[0-9a-f]{2}:[0-9a-f:]+
                       | fe80:[0-9a-f:]+
                    )\](?:[/:]|\z)
                )
            }xi) {
            $self->{logger}->log(4, "displayUrlTitle() skipping private/internal URL: $url");
            return undef;
        }
    
        $self->{logger}->log(4, "displayUrlTitle() URL: $url");
    
        # ── 1. YouTube ─────────────────────────────────────────────────────────
        # All YouTube URL variants (watch, shorts, live, youtu.be, nocookie, m., music.)
        my $yt_id = Mediabot::External::_is_youtube_url($url);
        if (defined $yt_id) {
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'Youtube')) {
                $self->{logger}->log(4, "displayUrlTitle() YouTube chanset not enabled on $sChannel");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            # Delegate to Mediabot::External::displayYoutubeDetails which uses the YouTube Data API v3
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'youtube' }) if $self->{metrics}; };
            return Mediabot::External::displayYoutubeDetails($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 2. Instagram ───────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?instagram\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Instagram)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'instagram' }) if $self->{metrics}; };
            return _handle_instagram($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 3. Spotify ─────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://open\.spotify\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Spotify)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'spotify' }) if $self->{metrics}; };
            return Mediabot::External::_handle_spotify($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 4. Apple Music ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://music\.apple\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'AppleMusic')) {
                $self->{logger}->log(4, "displayUrlTitle() AppleMusic chanset not enabled on $sChannel");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'applemusic' }) if $self->{metrics}; };
            return _handle_applemusic($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 5. Facebook ────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?facebook\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Facebook)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'facebook' }) if $self->{metrics}; };
            return _handle_facebook($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 6. X / Twitter ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?(?:x|twitter)\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (X/Twitter)");
                return undef;
            }
            return undef unless _url_display_cache_gate($self, $url, $sChannel);
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'x_twitter' }) if $self->{metrics}; };
            return _handle_x_twitter($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 7. Generic ─────────────────────────────────────────────────────────
        unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel");
            return undef;
        }
        return undef unless _url_display_cache_gate($self, $url, $sChannel);
        eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'generic' }) if $self->{metrics}; };
        return _handle_generic_title($self, $message, $sNick, $sChannel, $url);
    };
    if ($@) {
        $self->{logger}->log(1, "displayUrlTitle() error for $captured_url: $@");
    }
    return $result;

}

# debug [0-5]
# Show or set the bot debug level.
# Requires: authenticated + Owner

1;
