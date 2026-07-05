package Mediabot::External::URL;
# =============================================================================
# Mediabot::External::URL — URL title display, Instagram, Facebook, X/Twitter,
#                           Apple Music, generic titles
# =============================================================================
# mb99-R1: extrait de Mediabot::External.
# =============================================================================

use strict;
use warnings;
use Exporter 'import';
use JSON::MaybeXS;
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
    $str = decode_entities($str) if ($str =~ /$regex/ || $str =~ /&#[0-9]+;/);
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

    my @cmd = (
        $chromium,
        '--headless=new',
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

sub _handle_instagram {
    my ($self, $message, $nick, $channel, $url) = @_;

    $self->{logger}->log(4, "_handle_instagram() start url=$url");

    # IMP10: serve from cache if fresh (TTL 10 min)
    my $ig_cached = $self->{_instagram_cache}{lc($url)};
    if ($ig_cached && (time() - ($ig_cached->{ts} // 0)) < 600) {
        $self->{logger}->log(4, "_handle_instagram() cache hit for $url");
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $ig_cached->{msg}");
        return 1;
    }

    my ($shortcode) = $url =~ m{/(?:p|reel|tv)/([^/?#]+)/?};
    unless (defined $shortcode && $shortcode ne '') {
        $self->{logger}->log(3, "_handle_instagram() could not extract shortcode from $url");
        return undef;
    }

    my $title;

    # ------------------------------------------------------------
    # Step 1: one cheap HTTP fetch on the public page only
    # ------------------------------------------------------------
    my $http = Mediabot::External::_make_http(
        timeout  => 8,
        max_size => 1024 * 1024,
    );

    my $res = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'instagram-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_instagram() HTTP fetched $len bytes for $url");

        my $og_description;
        my $meta_description;
        my $title_tag;

        if ($content =~ /<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']/i) {
            $og_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:description["']/i) {
            $og_description = $1;
        }

        if ($content =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
            $meta_description = $1;
        }
        elsif ($content =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
            $meta_description = $1;
        }

        if ($content =~ /<title[^>]*>([^<]+)<\/title>/i) {
            $title_tag = $1;
        }

        for ($og_description, $meta_description, $title_tag) {
            $_ = _decode_html($_) if defined $_;
        }

        $self->{logger}->log(4, "_handle_instagram() HTTP og:description=" . (defined $og_description ? $og_description : '<undef>'));
        $self->{logger}->log(4, "_handle_instagram() HTTP meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
        $self->{logger}->log(4, "_handle_instagram() HTTP <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

        if (defined $og_description && $og_description ne '' && $og_description !~ /^\s*Instagram\s*$/i) {
            $title = $og_description;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP og:description");
        }
        elsif (defined $meta_description && $meta_description ne '' && $meta_description !~ /^\s*Instagram\s*$/i) {
            $title = $meta_description;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP meta description");
        }
        elsif (defined $title_tag && $title_tag ne '' && $title_tag !~ /^\s*Instagram\s*$/i) {
            $title = $title_tag;
            $self->{logger}->log(4, "_handle_instagram() selected HTTP <title>");
        }

        if (!defined($title) || $title eq '') {
            if ($content =~ /"pageID":"httpErrorPage"/) {
                $self->{logger}->log(4, "_handle_instagram() public page is an httpErrorPage shell for $url");
            }
        }
    }
    else {
        $self->{logger}->log(4, "_handle_instagram() HTTP $res->{status} $res->{reason} for $url");
    }

    # ------------------------------------------------------------
    # Step 2: Chromium fallback on the public page only
    # ------------------------------------------------------------
    unless (defined $title && $title ne '') {
        $self->{logger}->log(4, "_handle_instagram() falling back to Chromium rendered DOM on public URL");

        my $dom = _fetch_url_chromium_dumpdom($self, $url);
        if (defined $dom && $dom ne '') {
            my $len = length($dom);
            $self->{logger}->log(4, "_handle_instagram() Chromium DOM fetched $len bytes for $url");

            my $og_description;
            my $meta_description;
            my $title_tag;

            if ($dom =~ /<meta\s+property=["']og:description["']\s+content=["']([^"']+)["']/i) {
                $og_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+property=["']og:description["']/i) {
                $og_description = $1;
            }

            if ($dom =~ /<meta\s+name=["']description["']\s+content=["']([^"']+)["']/i) {
                $meta_description = $1;
            }
            elsif ($dom =~ /<meta\s+content=["']([^"']+)["']\s+name=["']description["']/i) {
                $meta_description = $1;
            }

            if ($dom =~ /<title[^>]*>([^<]+)<\/title>/i) {
                $title_tag = $1;
            }

            for ($og_description, $meta_description, $title_tag) {
                $_ = _decode_html($_) if defined $_;
            }

            $self->{logger}->log(4, "_handle_instagram() Chromium og:description=" . (defined $og_description ? $og_description : '<undef>'));
            $self->{logger}->log(4, "_handle_instagram() Chromium meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
            $self->{logger}->log(4, "_handle_instagram() Chromium <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

            if (defined $og_description
                && $og_description ne ''
                && $og_description !~ /^\s*Instagram\s*$/i
                && $og_description !~ /create an account or log in to instagram/i
            ) {
                $title = $og_description;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium og:description");
            }
            elsif (defined $meta_description
                && $meta_description ne ''
                && $meta_description !~ /^\s*Instagram\s*$/i
                && $meta_description !~ /create an account or log in to instagram/i
            ) {
                $title = $meta_description;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium meta description");
            }
            elsif (defined $title_tag
                && $title_tag ne ''
                && $title_tag !~ /^\s*Instagram\s*$/i
                && $title_tag !~ /create an account or log in to instagram/i
            ) {
                $title = $title_tag;
                $self->{logger}->log(4, "_handle_instagram() selected Chromium <title>");
            }
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_instagram() no usable title extracted for shortcode=" . ($shortcode // "undef"));
        return undef;
    }

    $title =~ s/\s+/ /g;
    $title =~ s/^\s+|\s+$//g;
    $title =~ s/\s*-\s*Watch more on Instagram\.?\s*$//i;
    $title =~ s/\s*[•·|]\s*Instagram\s*$//i;

    if ($title =~ /^\s*Instagram\s*$/i || $title =~ /DOCTYPE/i || $title eq '') {
        $self->{logger}->log(3, "_handle_instagram() extracted title is unusable after cleanup: '$title'");
        return undef;
    }

    $self->{logger}->log(4, "_handle_instagram() final title='$title'");

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("Instagram")->white('pink');
    $badge   .= String::IRC->new("]")->white('black');

    my $msg = "$badge\x0f " . substr($title, 0, 300);
    # IMP10: cache the result (TTL 10 min) to avoid redundant Chromium fetches
    $self->{_instagram_cache}{lc($url)} = { ts => time(), msg => $msg };

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
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
sub _handle_applemusic {
    my ($self, $message, $nick, $channel, $url) = @_;

    my $title;

    # ------------------------------------------------------------
    # Step 1: cheap HTTP fetch first
    # ------------------------------------------------------------
    my $http = Mediabot::External::_make_http(
        timeout  => 12,
        max_size => 512 * 1024,
    );
    my $res  = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'applemusic-http');

        my $og_title;
        my $meta_description;
        my $title_tag;

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

        $self->{logger}->log(4, "_handle_applemusic() HTTP og:title=" . (defined $og_title ? $og_title : '<undef>'));
        $self->{logger}->log(4, "_handle_applemusic() HTTP meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
        $self->{logger}->log(4, "_handle_applemusic() HTTP <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

        if (defined $og_title
            && $og_title ne ''
            && $og_title !~ /^\s*Apple Music\s*$/i
            && $og_title !~ /listen on apple music/i
            && $og_title !~ /open in music/i
        ) {
            $title = $og_title;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP og:title");
        }
        elsif (defined $meta_description
            && $meta_description ne ''
            && $meta_description !~ /^\s*Apple Music\s*$/i
            && $meta_description !~ /listen on apple music/i
            && $meta_description !~ /open in music/i
        ) {
            $title = $meta_description;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP meta description");
        }
        elsif (defined $title_tag
            && $title_tag ne ''
            && $title_tag !~ /^\s*Apple Music\s*$/i
            && $title_tag !~ /listen on apple music/i
            && $title_tag !~ /open in music/i
        ) {
            $title = $title_tag;
            $self->{logger}->log(4, "_handle_applemusic() selected HTTP <title>");
        }
    }
    else {
        $self->{logger}->log(3, "_handle_applemusic() HTTP $res->{status} $res->{reason} for $url");
    }

    # ------------------------------------------------------------
    # Step 2: Chromium fallback if HTTP title is missing or generic
    # ------------------------------------------------------------
    my $title_check = defined($title) ? $title : '';
    $title_check =~ s/\s+/ /g;
    $title_check =~ s/^\s+|\s+$//g;

    if (!defined($title) || $title_check eq '' || $title_check =~ /^\s*Apple Music\s*$/i) {
        $self->{logger}->log(4, "_handle_applemusic() falling back to Chromium rendered DOM for $url");

        my $dom = _fetch_url_chromium_dumpdom(
            $self,
            $url,
            virtual_time_budget => 10000,
            alarm_timeout       => 30,
        );

        if (defined $dom && $dom ne '') {
            my $og_title;
            my $meta_description;
            my $title_tag;

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

            $self->{logger}->log(4, "_handle_applemusic() Chromium og:title=" . (defined $og_title ? $og_title : '<undef>'));
            $self->{logger}->log(4, "_handle_applemusic() Chromium meta description=" . (defined $meta_description ? $meta_description : '<undef>'));
            $self->{logger}->log(4, "_handle_applemusic() Chromium <title>=" . (defined $title_tag ? $title_tag : '<undef>'));

            if (defined $og_title
                && $og_title ne ''
                && $og_title !~ /^\s*Apple Music\s*$/i
                && $og_title !~ /listen on apple music/i
                && $og_title !~ /open in music/i
            ) {
                $title = $og_title;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium og:title");
            }
            elsif (defined $meta_description
                && $meta_description ne ''
                && $meta_description !~ /^\s*Apple Music\s*$/i
                && $meta_description !~ /listen on apple music/i
                && $meta_description !~ /open in music/i
            ) {
                $title = $meta_description;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium meta description");
            }
            elsif (defined $title_tag
                && $title_tag ne ''
                && $title_tag !~ /^\s*Apple Music\s*$/i
                && $title_tag !~ /listen on apple music/i
                && $title_tag !~ /open in music/i
            ) {
                $title = $title_tag;
                $self->{logger}->log(4, "_handle_applemusic() selected Chromium <title>");
            }
        }
    }

    unless (defined $title && $title ne '') {
        $self->{logger}->log(3, "_handle_applemusic() could not extract title from $url");
        return undef;
    }

    $title =~ s/\s+/ /g;
    $title =~ s/^\s+|\s+$//g;

    my $badge = String::IRC->new("[")->white('black');
    $badge   .= String::IRC->new("AppleMusic")->white('grey');
    $badge   .= String::IRC->new("]")->white('black');

    my $msg = "$badge\x0f $title";

    Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) $msg");
    return 1;
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
    $title =~ s/\s{2,}/ /g;
    $title =~ s/^\s+|\s+$//g;

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
    );

    my $res = eval { $http->get($fb_url); } // { success => 0, status => 0, reason => $@ };

    if ($res->{success}) {
        my $content = _decode_http_content_utf8($self, $res->{content} // '', 'facebook-http');
        my $len = length($content);
        $self->{logger}->log(4, "_handle_facebook() HTTP fetched $len bytes for $fb_url");
        $title = _facebook_title_from_html($self, $content, 'HTTP');
    }
    else {
        $self->{logger}->log(4, "_handle_facebook() HTTP $res->{status} $res->{reason} for $fb_url");
    }

    # Step 2: Chromium fallback.  This is useful for Facebook shells where
    # the initial HTML is present but the useful title is rendered or altered.
    unless (defined $title && $title ne '') {
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
            $title = _facebook_title_from_html($self, $dom, 'Chromium');
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

    my $msg = "$badge\x0f " . substr($title, 0, 300);
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

    # X is rendered/client-heavy.  Go directly through Chromium, the same
    # strategy used for stubborn Facebook shells.
    # XT1/fix: eval around chromium call — external process may die/timeout
    my $dom = eval { _fetch_url_chromium_dumpdom(
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
    }
    else {
        $self->{logger}->log(4, "_handle_x_twitter() Chromium returned no usable DOM for $x_url");
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

    my $msg = "$badge\x0f " . substr($title, 0, 300);

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

    # IMP1: anti-repetition cache — skip if same URL posted in same channel < 5 min ago
    if (defined $url) {
        my $cache_key  = lc($url) . "\x00" . lc($sChannel // '');   # mb408-R1: canal lc (cohérent mb407)
        my $cache      = $self->{_url_display_cache} //= {};
        my $now        = time();
        my $url_ttl    = 300;  # 5 minutes
        # Purge stale entries (max once per 60s to avoid per-message cost)
        if (($self->{_url_cache_last_purge} // 0) < $now - 60) {
            my @stale = grep { ($cache->{$_} // 0) < $now - $url_ttl } keys %$cache;
            delete @{$cache}{@stale};
            $self->{_url_cache_last_purge} = $now;
        }
        if (($cache->{$cache_key} // 0) >= $now - $url_ttl) {
            $self->{logger}->log(4, "displayUrlTitle() skipping repeated URL: $url");
            return undef;
        }
        $cache->{$cache_key} = $now;
    }

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
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'instagram' }) if $self->{metrics}; };
            return _handle_instagram($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 3. Spotify ─────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://open\.spotify\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Spotify)");
                return undef;
            }
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'spotify' }) if $self->{metrics}; };
            return Mediabot::External::_handle_spotify($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 4. Apple Music ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://music\.apple\.com(?:[/:?#]|\z)}i) { # mb406-B1: host ancré
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'AppleMusic')) {
                $self->{logger}->log(4, "displayUrlTitle() AppleMusic chanset not enabled on $sChannel");
                return undef;
            }
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'applemusic' }) if $self->{metrics}; };
            return _handle_applemusic($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 5. Facebook ────────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?facebook\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (Facebook)");
                return undef;
            }
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'facebook' }) if $self->{metrics}; };
            return _handle_facebook($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 6. X / Twitter ─────────────────────────────────────────────────────
        if ($url =~ m{\Ahttps?://(?:www\.)?(?:x|twitter)\.com(?:/|\z)}i) { # mb416-B1: host anchored
            unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
                $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel (X/Twitter)");
                return undef;
            }
            eval { $self->{metrics}->inc('mediabot_urltitle_requests_total', { type => 'x_twitter' }) if $self->{metrics}; };
            return _handle_x_twitter($self, $message, $sNick, $sChannel, $url);
        }
    
        # ── 7. Generic ─────────────────────────────────────────────────────────
        unless (Mediabot::External::_chanset_ok($self, $sChannel, 'UrlTitle')) {
            $self->{logger}->log(4, "displayUrlTitle() UrlTitle chanset not enabled on $sChannel");
            return undef;
        }
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
