# t/cases/538_mb316_whereis_async_nonblocking.t
# =============================================================================
# MB316: whereis DNS + country.is lookup must not block the IRC event loop.
# The WHOIS callback must capture its reply context before async completion.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb316 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb316 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape = 0;
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

    my $helpers = _slurp_mb316(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );
    my $main = _slurp_mb316('mediabot.pl');

    my $async = _extract_sub_mb316($helpers, 'whereis_async');
    $assert->ok(defined $async, 'whereis_async helper found');

    $assert->like(
        $helpers,
        qr/^\s*whereis_async\s*$/m,
        'whereis_async is exported to the Mediabot package'
    );

    $assert->like(
        $async // '',
        qr/open\(my\s+\$pipe,\s*'-\|'\)/,
        'blocking resolver/API work runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/whereis\(\{\},\s*\$sHostname\)/,
        'child reuses the guarded synchronous lookup implementation'
    );

    $assert->like(
        $async // '',
        qr/POSIX::_exit\(0\)/,
        'forked child exits without running inherited bot destructors'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Stream->new/,
        'parent consumes the result pipe through IO::Async::Stream'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Timer::Countdown->new/,
        'lookup timeout and reap polling use asynchronous timers'
    );

    $assert->like(
        $async // '',
        qr/waitpid\(\$child_pid,\s*WNOHANG\)/,
        'child collection is non-blocking'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'TERM',\s*\$child_pid/,
        'timeout first sends TERM'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'KILL',\s*\$child_pid/,
        'timeout escalates to KILL when required'
    );

    $assert->like(
        $async // '',
        qr/my\s+\$remaining\s*=\s*256\s*-\s*length\(\$state->\{output\}\)/,
        'child output is bounded'
    );

    $assert->unlike(
        $async // '',
        qr/\b(?:sleep|usleep)\s*\(/,
        'whereis_async contains no blocking sleep'
    );

    $assert->unlike(
        $async // '',
        qr/select\s*\(undef\s*,\s*undef\s*,\s*undef/,
        'whereis_async contains no blocking select delay'
    );

    $assert->unlike(
        $async // '',
        qr/waitpid\s*\(\s*\$child_pid\s*,\s*0\s*\)/,
        'whereis_async contains no unconditional blocking waitpid'
    );

    my ($branch) = $main =~ /(elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"mbWhereis"\).*?\n\s*}\n\s*elsif\s*\(\$WHOIS_VARS\{'sub'\}\s+eq\s+"statPartyline")/s;
    $assert->ok(defined $branch, 'mbWhereis WHOIS branch found');

    $assert->like(
        $branch // '',
        qr/->whereis_async\s*\(/,
        'WHOIS callback schedules the non-blocking lookup'
    );

    $assert->unlike(
        $branch // '',
        qr/->whereis\s*\(/,
        'WHOIS callback no longer performs the blocking lookup directly'
    );

    $assert->like(
        $branch // '',
        qr/my\s+\$whereis_caller\s*=.*?my\s+\$whereis_nick\s*=.*?my\s+\$reply_target\s*=/s,
        'caller, requested nick and reply target are captured before async completion'
    );

    $assert->like(
        $branch // '',
        qr/Country\s*:\s*\$country/,
        'async callback preserves the existing user-visible reply'
    );

    # Exercise the compatibility path used when no IO::Async loop is available.
    {
        package MB316::Probe;
        our $RETURN = 'FR';
        sub WNOHANG () { 1 }
        sub whereis { return $RETURN }
    }

    my $compiled = eval "package MB316::Probe; use strict; use warnings; $async; 1;";
    $assert->ok($compiled, 'whereis_async compiles in isolation');

    my $bot = bless {}, 'MB316::Probe::Bot';
    my $received;
    my $started = MB316::Probe::whereis_async(
        $bot,
        'example.org',
        sub { $received = shift },
    );

    $assert->is($started, 1, 'no-loop compatibility path reports handled request');
    $assert->is($received, 'FR', 'no-loop compatibility path preserves lookup result');

    $MB316::Probe::RETURN = undef;
    $received = undef;
    MB316::Probe::whereis_async(
        $bot,
        'bad.example',
        sub { $received = shift },
    );
    $assert->is($received, 'N/A', 'undefined compatibility result is normalized to N/A');

    $assert->is(
        MB316::Probe::whereis_async($bot, 'example.org', 'not-a-callback'),
        0,
        'invalid callback is rejected safely'
    );
};
