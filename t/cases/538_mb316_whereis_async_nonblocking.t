# t/cases/538_mb316_whereis_async_nonblocking.t
# =============================================================================
# MB316: whereis DNS + country.is lookup must not block the IRC event loop.
# The WHOIS callback must capture its reply context before async completion.
# =============================================================================

use strict;
use warnings;

use File::Spec;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

sub _slurp_mb316 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
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

    my $country = _slurp_mb316('Mediabot/External/Country.pm');
    my $worker_source = _slurp_mb316('Mediabot/AsyncWorker.pm');
    my $async = _extract_sub_mb316($country, 'whereis_async');
    $assert->ok(defined $async, 'whereis_async helper found');

    $assert->like(
        $helpers,
        qr/^\s*whereis_async\s*$/m,
        'whereis_async is exported to the Mediabot package'
    );

    $assert->like(
        $async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'blocking resolver/API work runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/_compat_whereis\(\{\},\s*\$sHostname\)/,
        'child reuses the guarded synchronous lookup implementation'
    );

    $assert->like(
        $worker_source,
        qr/POSIX::_exit\(0\)/,
        'forked child exits without running inherited bot destructors'
    );

    $assert->like(
        $worker_source,
        qr/IO::Async::Stream->new/,
        'parent consumes the result pipe through IO::Async::Stream'
    );

    $assert->like(
        $worker_source,
        qr/IO::Async::Timer::Countdown->new/,
        'shared worker uses asynchronous timeout timers'
    );

    $assert->like(
        $worker_source,
        qr/\$loop->watch_process\(/,
        'shared worker gives child collection to the event loop'
    );

    $assert->like(
        $worker_source,
        qr/->_signal_child\('TERM'\)/,
        'timeout first sends TERM'
    );

    $assert->like(
        $worker_source,
        qr/->_signal_child\('KILL'\)/,
        'timeout escalates to KILL when required'
    );

    $assert->like(
        $async // '',
        qr/max_output\s*=>\s*1024\b/,
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

    # Exercise the loaded compatibility API, rather than a copied function.
    require Mediabot::Helpers;
    my $value = 'FR';
    no warnings 'redefine';
    local *Mediabot::Helpers::whereis = sub { return $value };
    my $bot = bless {}, 'MB316::Probe::Bot';
    my $received;
    my $started = Mediabot::Helpers::whereis_async($bot, 'example.org', sub { $received = shift });
    $assert->ok(defined &Mediabot::External::Country::whereis_async, 'canonical country adapter is loaded');
    $assert->is($started, 1, 'no-loop compatibility path reports handled request');
    $assert->is($received, 'FR', 'no-loop compatibility path preserves lookup result');
    $value = undef;
    $received = undef;
    Mediabot::Helpers::whereis_async($bot, 'bad.example', sub { $received = shift });
    $assert->is($received, 'N/A', 'undefined compatibility result is normalized to N/A');
    $assert->is(Mediabot::Helpers::whereis_async($bot, 'example.org', 'not-a-callback'),
        0, 'invalid callback is rejected safely');

    for my $order ('country', 'country-first', 'helpers-first') {
        my $code = q{
            use strict; use warnings;
            require HTTP::Tiny;
            no warnings qw(redefine once);
            local *HTTP::Tiny::new = sub { die "unexpected network client" };
        };
        $code .= 'require Mediabot::Helpers;' if $order eq 'helpers-first';
        $code .= q{
            require Mediabot::External::Country;
            Mediabot::External::Country->import();
            die "default export" if defined &main::whereis;
            Mediabot::External::Country->import(qw(whereis whereis_async));
            die "imports" unless defined &main::whereis && defined &main::whereis_async;
        };
        $code .= q{
            die "cold dependency" if $INC{'Mediabot/Helpers.pm'} || $INC{'Mediabot/External.pm'} || $INC{'DBI.pm'};
        } if $order eq 'country';
        $code .= 'require Mediabot::Helpers;' if $order eq 'country-first';
        $code .= q{
            die "guard" unless whereis({}, undef) eq 'N/A';
            die "hidden host" unless whereis({}, 'test.users.undernet.org') eq 'on an Undernet hidden host ;)';
            local *HTTP::Tiny::new = sub { return bless {}, 'MB899::ColdHTTP' };
            local *MB899::ColdHTTP::get = sub { return {success=>1,content=>' {"country":" FR "} '} };
            die "cold JSON/Socket" unless whereis({}, '192.0.2.1') eq 'FR';
            print "ok";
        };
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-e', $code);
        my $stdout = do { local $/; <$out> // '' };
        my $stderr = do { local $/; <$err> // '' };
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'ok' && $stderr eq '',
            "country module load order $order is quiet and preserves guards ($stderr)");
    }

    # Late Socket/JSON hooks used through Helpers must still reach the owner.
    {
        no warnings qw(redefine once);
        my @calls;
        local *Mediabot::Helpers::inet_aton = sub { push @calls, ['aton', @_]; return 'packed' };
        local *Mediabot::Helpers::inet_ntoa = sub { push @calls, ['ntoa', @_]; return '192.0.2.1' };
        local *Mediabot::Helpers::decode_json = sub { push @calls, ['json', @_]; return {country=>' FR '} };
        local *HTTP::Tiny::new = sub { shift; push @calls, ['http', @_]; return bless {}, 'MB899::CountryHTTP' };
        local *MB899::CountryHTTP::get = sub { push @calls, ['get', $_[1]]; return {success=>1,content=>'hooked'} };
        my $got = Mediabot::External::Country::whereis({}, '192.0.2.1');
        $assert->ok($got eq 'FR' && @calls == 5 && $calls[0][0] eq 'aton'
            && $calls[1][0] eq 'ntoa' && $calls[2][0] eq 'http'
            && $calls[3][1] eq 'https://api.country.is/192.0.2.1' && $calls[4][1] eq 'hooked',
            'canonical lookup preserves late legacy Socket, JSON and HTTP hooks');
    }
    for my $mode ('timeout', 'ignore-term') {
        my $code = q{
            use strict; use warnings;
            use IO::Async::Loop;
            use POSIX qw(WNOHANG);
            use Time::HiRes qw(time);
            require Mediabot::Helpers;
            require Mediabot::External::Country;
            my $mode = shift;
            my $loop = IO::Async::Loop->new;
            my $bot = bless {loop=>$loop}, 'MB899::NativeBot';
            no warnings qw(redefine once);
            local *Mediabot::Helpers::whereis = sub {
                $SIG{TERM} = 'IGNORE' if $mode eq 'ignore-term';
                select undef, undef, undef, 2;
                return 'FR';
            };
            my @got;
            my $started = Mediabot::External::Country::whereis_async(
                $bot, 'unused.example', sub {push @got, @_}, timeout=>0.1);
            my $deadline = time + 3;
            $loop->loop_once(0.02) while !@got && time < $deadline;
            $loop->loop_once(0.01) for 1..3;
            die 'start' unless $started == 1;
            die 'callback' unless @got == 1 && $got[0] eq 'N/A';
            die 'unreaped child' unless waitpid(-1, WNOHANG) == -1;
            print 'ok';
        };
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-e', $code, $mode);
        my $stdout = do {local $/; <$out> // ''};
        my $stderr = do {local $/; <$err> // ''};
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'ok' && $stderr eq '',
            "native country worker $mode calls back once and reaps its child ($stderr)");
    }
    # MB900: exercise the real owner with native pipes, timers and reaping.
    require MB900PipeFixture;
    for my $mode ('nominal', 'early-eof') {
        my $result = MB900PipeFixture::probe('country', $mode);
        $assert->ok($result->{ok},
            "mb900: country native $mode preserves status and loop responsiveness: " . $result->{detail});
    }
};
