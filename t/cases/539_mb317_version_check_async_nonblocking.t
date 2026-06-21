# t/cases/539_mb317_version_check_async_nonblocking.t
# =============================================================================
# MB317: the runtime version command must not perform DNS/GitHub I/O in the IRC
# event loop. Startup keeps the existing synchronous getVersion() path.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb317 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
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
    my $async = _extract_sub_mb317($src, 'getVersion_async');
    my $command = _extract_sub_mb317($src, 'versionCheck');
    my $sync = _extract_sub_mb317($src, 'getVersion');

    $assert->ok(defined $sync, 'existing synchronous getVersion helper remains available');
    $assert->ok(defined $async, 'getVersion_async helper found');
    $assert->ok(defined $command, 'versionCheck command found');

    $assert->like(
        $src,
        qr/^\s*getVersion_async\s*$/m,
        'getVersion_async is exported'
    );

    $assert->like(
        $async // '',
        qr/open\(my\s+\$pipe,\s*'-\|'\)/,
        'blocking GitHub lookup runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/getVersion\(\$self\)/,
        'child reuses the existing guarded version implementation'
    );

    $assert->like(
        $async // '',
        qr/Mediabot::Helpers::_SilentLogger/,
        'forked version worker suppresses duplicate child logs'
    );

    $assert->like(
        $async // '',
        qr/POSIX::_exit\(0\)/,
        'forked child exits without inherited destructors'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Stream->new/,
        'parent consumes version result asynchronously'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Timer::Countdown->new/,
        'timeout and reap polling use asynchronous timers'
    );

    $assert->like(
        $async // '',
        qr/waitpid\(\$child_pid,\s*WNOHANG\)/,
        'version worker is reaped non-blockingly'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'TERM',\s*\$child_pid/,
        'timeout sends TERM first'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'KILL',\s*\$child_pid/,
        'timeout escalates to KILL'
    );

    $assert->like(
        $async // '',
        qr/my\s+\$remaining\s*=\s*1024\s*-\s*length\(\$state->\{output\}\)/,
        'child output is bounded'
    );

    $assert->like(
        $async // '',
        qr/decode_json\(\$state->\{output\}/,
        'parent validates the structured child payload'
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
        $command // '',
        qr/return\s+getVersion_async\s*\(/,
        'runtime version command schedules the asynchronous helper'
    );

    $assert->unlike(
        $command // '',
        qr/->getVersion\s*\(/,
        'runtime version command no longer performs the synchronous lookup'
    );

    $assert->like(
        $command // '',
        qr/my\s+\$message\s*=\s*\$ctx->message/,
        'command captures its log context before async completion'
    );

    $assert->like(
        $command // '',
        qr/\$self->\{main_prog_version\}\s*=\s*\$local_version/,
        'parent runtime version state is refreshed after completion'
    );

    $assert->like(
        $command // '',
        qr/\$ctx->reply\(\$sMsg\)/,
        'existing public/private reply behavior is preserved'
    );

    $assert->like(
        $command // '',
        qr/logBot\(\$self,\s*\$message,\s*undef,\s*'version'/,
        'command logging occurs after the asynchronous reply'
    );

    $assert->like(
        $async // '',
        qr/unless\s*\(\$loop\s*&&.*?getVersion\(\$self\)/s,
        'no-loop compatibility path keeps the historical synchronous behavior'
    );
};
