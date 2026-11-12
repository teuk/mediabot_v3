# t/cases/539_mb317_version_check_async_nonblocking.t
# =============================================================================
# MB317: the runtime version command must not perform DNS/GitHub I/O in the IRC
# event loop. Startup is local-only; explicit runtime checks use the async path.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb317 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb317 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
            }
            elsif ($ch eq '\\') {
                $escape = 1;
            }
            elsif ($ch eq $quote) {
                undef $quote;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
        }
        elsif ($ch eq q{'}) {
            $quote = q{'};
        }
        elsif ($ch eq q{"}) {
            $quote = q{"};
        }
        elsif ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb317(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $remote = _slurp_mb317(File::Spec->catfile('.', 'Mediabot', 'Version', 'Remote.pm'));
    my $main = _slurp_mb317(File::Spec->catfile('.', 'mediabot.pl'));
    my $async = _extract_sub_mb317($remote, 'getVersion_async');
    my $sync = _extract_sub_mb317($remote, 'getVersion');

    $assert->ok(defined $sync, 'existing synchronous getVersion helper remains available');
    $assert->ok(defined $async, 'getVersion_async helper found');
    require MB1242VersionCommand;
    MB1242VersionCommand::check(sub { $assert->ok($_[0], $_[1]) }, 'component');
    MB1242VersionCommand::check(sub { $assert->ok($_[0], $_[1]) }, 'facade');

    $assert->like(
        $main,
        qr/\$MAIN_PROG_VERSION\s*=\s*\$mediabot->getLocalVersion\(\)/,
        'startup reads only the local version identity'
    );

    $assert->unlike(
        $main,
        qr/\$mediabot->getVersion\(\)/,
        'startup no longer performs the synchronous GitHub check'
    );

    $assert->like(
        $src,
        qr/^\s*getVersion_async\s*$/m,
        'getVersion_async is exported'
    );

    $assert->like(
        $src,
        qr/use\s+Mediabot::AsyncWorker;/,
        'version helper loads the shared AsyncWorker contract'
    );

    $assert->like(
        $async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'blocking GitHub lookup is delegated to the shared worker'
    );

    $assert->like(
        $async // '',
        qr/child\s*=>\s*sub\s*\{.*?getVersion\(\$self\)/s,
        'shared-worker child reuses the existing guarded version implementation'
    );

    $assert->like(
        $async // '',
        qr/Mediabot::Helpers::_SilentLogger/,
        'forked version worker suppresses duplicate child logs'
    );

    $assert->like(
        $async // '',
        qr/max_output\s*=>\s*1024/,
        'version adapter keeps its historical bounded output budget'
    );

    $assert->like(
        $async // '',
        qr/term_grace\s*=>\s*0\.2.*?force_grace\s*=>\s*2/s,
        'version adapter preserves TERM/KILL and liveness timing policy'
    );

    $assert->like(
        $async // '',
        qr/ref\(\$result\)\s+eq\s+'HASH'.*?\$result->\{ok\}.*?ref\(\$value\)\s+ne\s+'ARRAY'/s,
        'parent validates the structured shared-worker result'
    );

    $assert->like(
        $async // '',
        qr/_version_asyncworker_reason\(\$result\)/,
        'worker lifecycle failures are translated into version-specific reasons'
    );

    my $async_exec = $async // '';
    $async_exec =~ s/#.*$//mg;

    $assert->unlike(
        $async_exec,
        qr/\b(?:pipe|fork|waitpid)\s*\(/,
        'version adapter no longer owns pipe/fork/reaping mechanics'
    );

    $assert->unlike(
        $async_exec,
        qr/\bwatch_process\s*\(/,
        'version adapter no longer owns process-watch mechanics'
    );

    $assert->unlike(
        $async_exec,
        qr/IO::Async::(?:Stream|Timer::Countdown)->new/,
        'version adapter no longer creates lifecycle streams or timers'
    );

    $assert->unlike(
        $async_exec,
        qr/\bkill\s+['"](?:TERM|KILL)['"]/,
        'version adapter no longer sends lifecycle signals itself'
    );

    $assert->unlike(
        $async // '',
        qr/\b(?:sleep|usleep)\s*\(/,
        'async version helper contains no blocking sleep'
    );

    $assert->unlike(
        $async // '',
        qr/select\s*\(undef\s*,\s*undef\s*,\s*undef/,
        'async version helper contains no blocking select delay'
    );

    $assert->unlike(
        $async // '',
        qr/waitpid\s*\(\s*\$child_pid\s*,\s*0\s*\)/,
        'async version helper contains no blocking waitpid'
    );

    $assert->like(
        $async // '',
        qr/my\s+\$fallback_local\s*=\s*_cached_local_version\(\$self\)/,
        'async worker keeps the cached local version for failure paths'
    );

    $assert->like(
        $async // '',
        qr/unless\s*\(\$loop\s*&&.*?getVersion\(\$self\)/s,
        'no-loop compatibility path keeps the historical synchronous behavior'
    );
};
