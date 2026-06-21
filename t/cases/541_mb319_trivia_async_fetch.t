# t/cases/541_mb319_trivia_async_fetch.t
# =============================================================================
# MB319:
#   - Open Trivia DB DNS/HTTP work must not run in the IRC event loop;
#   - concurrent fetches per channel must be serialized;
#   - failed fetches must not consume a multi-round round;
#   - remote JSON shapes must be validated before live game state is replaced.
# =============================================================================

use strict;
use warnings;
use File::Spec;

sub _slurp_mb319 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb319 {
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
            return substr($src, $start, $pos + 1 - $start)
                if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb319(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $parse   = _extract_sub_mb319($src, '_trivia_parse_api_content');
    my $sync    = _extract_sub_mb319($src, '_trivia_fetch_sync');
    my $async   = _extract_sub_mb319($src, '_trivia_fetch_async');
    my $command = _extract_sub_mb319($src, 'mbTrivia_ctx');
    my $stop    = _extract_sub_mb319($src, 'mbTriviaStop_ctx');

    $assert->ok(defined $parse,   'trivia API parser found');
    $assert->ok(defined $sync,    'synchronous trivia request core found');
    $assert->ok(defined $async,   'asynchronous trivia request wrapper found');
    $assert->ok(defined $command, 'trivia command found');
    $assert->ok(defined $stop,    'trivia stop command found');

    $assert->like(
        $sync // '',
        qr/_make_http\s*\([^)]*timeout\s*=>\s*8/s,
        'synchronous worker retains the existing bounded HTTP timeout'
    );

    $assert->like(
        $sync // '',
        qr/max_size\s*=>\s*64\s*\*\s*1024/,
        'Open Trivia DB response size is bounded'
    );

    $assert->like(
        $sync // '',
        qr/_trivia_parse_api_content\(\$response->\{content\}\)/,
        'remote JSON is validated before it leaves the worker'
    );

    $assert->like(
        $async // '',
        qr/open\(my\s+\$pipe,\s*'-\|'\)/,
        'blocking trivia work runs in a child process'
    );

    $assert->like(
        $async // '',
        qr/_trivia_fetch_sync\(\$category_id,\s*\$difficulty\)/,
        'child reuses the guarded synchronous request implementation'
    );

    $assert->like(
        $async // '',
        qr/POSIX::_exit\(0\)/,
        'forked trivia child exits without inherited destructors'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Stream->new/,
        'parent consumes the trivia result asynchronously'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Timer::Countdown->new/,
        'timeout and child reaping use asynchronous timers'
    );

    $assert->like(
        $async // '',
        qr/waitpid\(\$child_pid,\s*POSIX::WNOHANG\(\)\)/,
        'trivia worker is reaped non-blockingly'
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

    $assert->unlike(
        $async // '',
        qr/\b(?:sleep|usleep)\s*\(/,
        'async trivia helper contains no blocking sleep'
    );

    $assert->unlike(
        $async // '',
        qr/select\s*\(undef\s*,\s*undef\s*,\s*undef/,
        'async trivia helper contains no blocking select delay'
    );

    $assert->unlike(
        $async // '',
        qr/waitpid\s*\(\s*\$child_pid\s*,\s*0\s*\)/,
        'async trivia helper contains no blocking waitpid'
    );

    $assert->like(
        $command // '',
        qr/return\s+_trivia_fetch_async\s*\(/,
        'runtime trivia command schedules asynchronous fetch'
    );

    $assert->unlike(
        $command // '',
        qr/\$http->get\s*\(|_make_http\s*\(/,
        'runtime trivia command no longer performs HTTP directly'
    );

    $assert->like(
        $command // '',
        qr/A trivia question request is already in progress/,
        'duplicate per-channel fetches are rejected clearly'
    );

    $assert->like(
        $command // '',
        qr/\$pending->\{token\}\s+eq\s+\$request_token/,
        'late callbacks must still own the current per-channel request token'
    );

    $assert->like(
        $command // '',
        qr/Discarding stale trivia result/,
        'a fetched result cannot overwrite a question activated meanwhile'
    );

    $assert->like(
        $command // '',
        qr/Unknown trivia category/,
        'unknown named categories receive an explicit diagnostic'
    );

    $assert->like(
        $command // '',
        qr/\$\{trivia_timeout\}s/,
        'question text reports the configured timeout instead of hard-coded 30s'
    );

    my $result_guard_pos = index(
        $command // '',
        q{unless (ref($result) eq 'HASH'},
    );
    my $round_increment_pos = index(
        $command // '',
        '$multi_current++;',
    );

    $assert->ok(
        $result_guard_pos >= 0
            && $round_increment_pos > $result_guard_pos,
        'multi-round counter advances only after a successful usable response'
    );

    $assert->like(
        $stop // '',
        qr/delete\s+\$self->\{_trivia_fetch\}\{\$channel\}/,
        'triviastop invalidates an outstanding fetch token'
    );

    $assert->like(
        $stop // '',
        qr/Pending trivia question request cancelled/,
        'triviastop confirms pending-request cancellation'
    );

    # Execute the pure parser independently of network and Mediabot runtime
    # dependencies.
    my $compiled = eval "package MB319::Probe;\n$parse\n1;";
    $assert->ok($compiled, 'trivia API parser compiles in isolation');

    my $valid_json = <<'JSON';
{
  "response_code": 0,
  "results": [
    {
      "type": "multiple",
      "difficulty": "Medium",
      "category": "Science & Nature",
      "question": "What is H&lt;sub&gt;2&lt;/sub&gt;O?",
      "correct_answer": "Water",
      "incorrect_answers": ["Oxygen", "Hydrogen", "Salt"]
    }
  ]
}
JSON

    my $valid = MB319::Probe::_trivia_parse_api_content($valid_json);

    $assert->ok(ref($valid) eq 'HASH', 'valid Open Trivia DB payload is accepted');
    $assert->is(
        $valid->{correct_answer},
        'Water',
        'correct answer is preserved'
    );
    $assert->is(
        scalar @{ $valid->{incorrect_answers} },
        3,
        'all incorrect answers are preserved'
    );
    $assert->is(
        $valid->{difficulty},
        'medium',
        'difficulty is normalized deterministically'
    );
    $assert->is(
        $valid->{category},
        'Science & Nature',
        'category is preserved'
    );

    my $api_error = MB319::Probe::_trivia_parse_api_content(
        '{"response_code":1,"results":[]}'
    );
    $assert->ok(!defined $api_error, 'non-zero API response code is rejected');

    my $missing_answers = MB319::Probe::_trivia_parse_api_content(
        '{"response_code":0,"results":[{"question":"Q","correct_answer":"A","incorrect_answers":[]}]}'
    );
    $assert->ok(
        !defined $missing_answers,
        'question without incorrect choices is rejected'
    );

    my $bad_shape = MB319::Probe::_trivia_parse_api_content(
        '{"response_code":0,"results":{"question":"Q"}}'
    );
    $assert->ok(!defined $bad_shape, 'malformed results shape is rejected');

    my $oversized = MB319::Probe::_trivia_parse_api_content(
        'x' x (64 * 1024 + 1)
    );
    $assert->ok(!defined $oversized, 'oversized API content is rejected');
};
