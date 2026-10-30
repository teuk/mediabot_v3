# t/cases/540_mb318_define_async_deterministic.t
# =============================================================================
# MB318:
#   - Wiktionary DNS/HTTP work must not run in the IRC event loop;
#   - language selection must prefer DEFINE_LANG and remain deterministic;
#   - public/private replies must use the Context reply helper.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb318 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb318 {
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

    # MB888: independent source imports and the historical async hook contract.
    require IPC::Open3;
    require Symbol;
    require Mediabot::UserCommands;
    for my $order (
        [qw(External::Wiktionary)],
        [qw(External::Wiktionary UserCommands)],
        [qw(UserCommands External::Wiktionary)],
    ) {
        my $code = join('', map {"require Mediabot::$_;\n"} @$order);
        if (@$order == 1) {
            $code .= q{die 'commands loaded eagerly' if $INC{'Mediabot/UserCommands.pm'};};
            $code .= q{die 'HTTP facade loaded eagerly' if $INC{'Mediabot/External.pm'};};
        }
        else {
            $code .= q{require Scalar::Util;
                for my $name (qw(_define_pick_entry _define_lookup_sync _define_lookup_async)) {
                    die 'legacy owner mismatch' unless
                        Scalar::Util::refaddr(Mediabot::UserCommands->can($name)) ==
                        Scalar::Util::refaddr(Mediabot::External::Wiktionary->can($name));
                }};
        }
        $code .= q{print 'loaded';};
        my $err = Symbol::gensym();
        my $pid = IPC::Open3::open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do {local $/; <$out>} // '';
        my $stderr = do {local $/; <$err>} // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'mb888: Wiktionary imports quietly with canonical legacy aliases: ' . join('/', @$order));
    }
    {
        no warnings 'redefine';
        my (@done, $calls);
        local *Mediabot::UserCommands::_define_lookup_sync = sub {
            $calls++;
            return 'legacy source hook';
        };
        my $ret = Mediabot::UserCommands::_define_lookup_async({}, 'probe', 'fr', sub {push @done, $_[0]});
        $assert->ok($ret == 1 && $calls == 1 && @done == 1 && $done[0] eq 'legacy source hook',
            'mb888: real define async adapter still honors a runtime legacy source override');
    }

    my $src = _slurp_mb318(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );
    my $source = _slurp_mb318(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Wiktionary.pm')
    );

    my $worker_source = _slurp_mb318('Mediabot/AsyncWorker.pm');
    my $pick    = _extract_sub_mb318($source, '_define_pick_entry');
    my $sync    = _extract_sub_mb318($source, '_define_lookup_sync');
    my $async   = _extract_sub_mb318($source, '_define_lookup_async');
    my $command = _extract_sub_mb318($src, 'mbDefine_ctx');

    $assert->ok(defined $pick,    'deterministic definition selector found');
    $assert->ok(defined $sync,    'synchronous lookup core found');
    $assert->ok(defined $async,   'asynchronous lookup wrapper found');
    $assert->ok(defined $command, 'define command found');

    $assert->like(
        $sync // '',
        qr/_define_pick_entry\(\$data,\s*\$lang\)/,
        'lookup uses the deterministic language selector'
    );

    $assert->like(
        $pick // '',
        qr/exists\s+\$data->\{\$preferred_lang\}/,
        'preferred DEFINE_LANG block is considered first'
    );

    $assert->like(
        $pick // '',
        qr/sort\s+keys\s+%\$data/,
        'fallback language order is deterministic'
    );

    $assert->unlike(
        $sync // '',
        qr/values\s+%\$data/,
        'lookup no longer selects an arbitrary hash value'
    );

    $assert->like(
        $async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'blocking Wiktionary work runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/_compat_define\(\{\},\s*\$word,\s*\$lang\)/,
        'child reuses the guarded synchronous lookup implementation'
    );

    $assert->like(
        $worker_source,
        qr/POSIX::_exit\(0\)/,
        'forked child exits without inherited destructors'
    );

    $assert->like(
        $worker_source,
        qr/IO::Async::Stream->new/,
        'parent consumes the result asynchronously'
    );

    $assert->like(
        $worker_source,
        qr/IO::Async::Timer::Countdown->new/,
        'shared worker uses asynchronous timeout timers'
    );

    $assert->like(
        $worker_source,
        qr/\$loop->watch_process\(/,
        'shared worker gives definition child collection to the event loop'
    );

    $assert->like(
        $worker_source,
        qr/->_signal_child\('TERM'\)/,
        'timeout sends TERM first'
    );

    $assert->like(
        $worker_source,
        qr/->_signal_child\('KILL'\)/,
        'timeout escalates to KILL'
    );

    $assert->like(
        $async // '',
        qr/max_output\s*=>\s*8192\b/,
        'child output is bounded'
    );

    $assert->unlike(
        $async // '',
        qr/\b(?:sleep|usleep)\s*\(/,
        'async define helper contains no blocking sleep'
    );

    $assert->unlike(
        $async // '',
        qr/select\s*\(undef\s*,\s*undef\s*,\s*undef/,
        'async define helper contains no blocking select delay'
    );

    $assert->unlike(
        $async // '',
        qr/waitpid\s*\(\s*\$child_pid\s*,\s*0\s*\)/,
        'async define helper contains no blocking waitpid'
    );

    $assert->like(
        $command // '',
        qr/return\s+_define_lookup_async\s*\(/,
        'runtime define command schedules asynchronous lookup'
    );

    $assert->unlike(
        $command // '',
        qr/\$http->get\s*\(|_make_http\s*\(/,
        'runtime command no longer performs HTTP directly'
    );

    $assert->like(
        $command // '',
        qr/\$ctx->reply\(\$message\)/,
        'result uses Context reply routing for public and private commands'
    );

    # Execute the pure selection helper to prove preferred-language and
    # deterministic fallback behavior independently of network dependencies.
    my $compiled = eval "package MB318::Probe;\n$pick\n1;";
    $assert->ok($compiled, 'definition selector compiles in isolation');

    my $data = {
        zz => [
            {
                partOfSpeech => 'noun',
                definitions  => [ { definition => 'Zed definition' } ],
            },
        ],
        en => [
            {
                partOfSpeech => 'noun',
                definitions  => [ { definition => 'English definition' } ],
            },
        ],
        aa => [
            {
                partOfSpeech => 'noun',
                definitions  => [ { definition => 'Alpha definition' } ],
            },
        ],
    };

    my ($preferred_entry, $preferred_text, $preferred_lang)
        = MB318::Probe::_define_pick_entry($data, 'en');

    $assert->is(
        $preferred_text,
        'English definition',
        'requested language definition is selected first'
    );

    $assert->is(
        $preferred_lang,
        'en',
        'selected language reports the requested language key'
    );

    my ($fallback_entry, $fallback_text, $fallback_lang)
        = MB318::Probe::_define_pick_entry($data, 'fr');

    $assert->is(
        $fallback_text,
        'Alpha definition',
        'missing preferred language falls back in sorted key order'
    );

    $assert->is(
        $fallback_lang,
        'aa',
        'deterministic fallback reports the first sorted usable key'
    );

    my ($bad_entry, $bad_text, $bad_lang)
        = MB318::Probe::_define_pick_entry(
            {
                en => [
                    undef,
                    { definitions => 'not-an-array' },
                    { definitions => [ {}, { definition => [] } ] },
                ],
            },
            'en',
        );

    $assert->ok(
        !defined($bad_entry) && !defined($bad_text) && !defined($bad_lang),
        'malformed Wiktionary response shapes are rejected safely'
    );
    # MB900: exercise the real owner with native pipes, timers and reaping.
    require MB900PipeFixture;
    for my $mode ('nominal', 'early-eof') {
        my $result = MB900PipeFixture::probe('define', $mode);
        $assert->ok($result->{ok},
            "mb900: define native $mode preserves status and loop responsiveness: " . $result->{detail});
    }
};
