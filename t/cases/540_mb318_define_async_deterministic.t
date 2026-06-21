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
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
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

    my $src = _slurp_mb318(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $pick    = _extract_sub_mb318($src, '_define_pick_entry');
    my $sync    = _extract_sub_mb318($src, '_define_lookup_sync');
    my $async   = _extract_sub_mb318($src, '_define_lookup_async');
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
        qr/open\(my\s+\$pipe,\s*'-\|'\)/,
        'blocking Wiktionary work runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/_define_lookup_sync\(\{\},\s*\$word,\s*\$lang\)/,
        'child reuses the guarded synchronous lookup implementation'
    );

    $assert->like(
        $async // '',
        qr/POSIX::_exit\(0\)/,
        'forked child exits without inherited destructors'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Stream->new/,
        'parent consumes the result asynchronously'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Timer::Countdown->new/,
        'timeouts and child reaping use asynchronous timers'
    );

    $assert->like(
        $async // '',
        qr/waitpid\(\$child_pid,\s*POSIX::WNOHANG\(\)\)/,
        'define worker is reaped non-blockingly'
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
        qr/my\s+\$remaining\s*=\s*4096\s*-\s*length\(\$state->\{output\}\)/,
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
};
