package Mediabot::External::Chromium;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode qw(decode);
use Time::HiRes qw(usleep);
use IPC::Open3;
use Symbol qw(gensym);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use IO::Select;
use POSIX qw(WNOHANG);

our $VERSION = '1.00';
our @EXPORT_OK = qw(
    _fetch_url_chromium_dumpdom
    _wait_chromium_child
    _decode_chromium_wait_status
);

# Keep the existing fixed executable. This private dependency seam lets native
# process tests use an isolated local fixture without changing the system binary.
sub _chromium_binary { return '/usr/bin/chromium'; }
sub _chromium_profile_base { return '/tmp/mediabot-chromium'; }

# Retain at most the remaining raw pipe-byte budget. Reading must continue
# after it is exhausted so a child cannot block on its stdout/stderr pipe.
sub _append_bounded_chunk {
    my ($buffer, $chunk, $limit) = @_;
    my $remaining = $limit - length($$buffer);
    return unless $remaining > 0;
    $$buffer .= length($chunk) > $remaining
        ? substr($chunk, 0, $remaining)
        : $chunk;
    return;
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

    my $chromium = _chromium_binary();
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
    my $profile_base = _chromium_profile_base();
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
                    _append_bounded_chunk(\$stdout, $chunk, $max_stdout);
                }
                else {
                    _append_bounded_chunk(\$stderr_txt, $chunk, $max_stderr);
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


1;

__END__

=head1 NAME

Mediabot::External::Chromium - Existing bounded dump-DOM subprocess wrapper.

=head1 CONTRACT

C<_fetch_url_chromium_dumpdom($bot, $url, %options)> preserves the existing
HTTP(S) argument guard, fixed executable, argv list, profile policy, concurrent
pipe draining, request deadline, TERM/KILL cleanup, decoding and diagnostics.
It is synchronous. Callers retain responsibility for worker dispatch and their
provider fallback, cache, routing and output policies.

The private path dependencies return C</usr/bin/chromium> and the existing
C</tmp/mediabot-chromium> profile base. There is no new configuration or caller
option for choosing either path. URL and External retain
their historical fetch symbols; URL also retains the two private wait helpers.
Shared HTML parsing and content decoding remain with their existing owners.

The existing C<max_stdout> and C<max_stderr> options bound retained raw bytes
exactly, including a read crossing a limit. Surplus bytes are still drained.
This is prefix retention, not whole-response rejection. A retained prefix that
ends inside a UTF-8 sequence uses the existing raw-buffer decode fallback.

=cut
