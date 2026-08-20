# t/cases/614_mb396_trivia_stage_protocol_deadline.t
# =============================================================================
# MB396:
#   - replace magic open '-|' ownership with an ordinary pipe + fork;
#   - stream bounded worker progress records into the parent logger;
#   - enforce a hard wall around HTTP::Tiny get(), including DNS/TLS stalls;
#   - guarantee a callback after timeout even if child notification is delayed.
# =============================================================================

use strict;
use warnings;
use File::Spec;
use Time::HiRes qw(time sleep);

sub _slurp_mb396 {
    my ($path) = @_;
    open my $fh, '<:raw', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb396 {
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

{
    package MB396::HTTP;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub get {
        my ($self) = @_;
        Time::HiRes::sleep($self->{sleep_for})
            if $self->{sleep_for};
        return $self->{response};
    }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb396(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $parse = _extract_sub_mb396($src, '_trivia_parse_api_content');
    my $sync  = _extract_sub_mb396($src, '_trivia_fetch_sync');
    my $async = _extract_sub_mb396($src, '_trivia_fetch_async');

    $assert->ok(defined $parse, 'trivia parser found');
    $assert->ok(defined $sync,  'trivia synchronous worker found');
    $assert->ok(defined $async, 'trivia asynchronous worker found');

    my $worker_src = _slurp_mb396(
        File::Spec->catfile('.', 'Mediabot', 'AsyncWorker.pm')
    );

    $assert->like(
        $async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'trivia uses the shared explicit pipe/fork worker contract'
    );

    $assert->unlike(
        $async // '',
        qr/open\(my\s+\$pipe,\s*'-\|'\)/,
        q{trivia adapter never reintroduces magic open '-|'}
    );

    $assert->like(
        $worker_src,
        qr/\bpipe\(\$read_fh,\s*\$write_fh\).*?\bmy \$pid = fork\(\)/s,
        'shared worker owns ordinary pipe + explicit fork'
    );

    $assert->like(
        $sync // '',
        qr/Time::HiRes::alarm\(\$hard_timeout\)/,
        'each HTTP request has a hard wall deadline'
    );

    $assert->like(
        $sync // '',
        qr/error\s*=>\s*'http_timeout'/,
        'hard request deadline has a distinct failure class'
    );

    $assert->like(
        $sync // '',
        qr/progress_cb/,
        'synchronous worker accepts a progress callback'
    );

    $assert->like(
        $async // '',
        qr/on_progress\s*=>\s*\$progress/,
        'child progress is routed through the shared worker protocol'
    );

    $assert->like(
        $async // '',
        qr/\$last_stage\s*=\s*\$stage/,
        'timeout diagnostics preserve the last observed child stage'
    );

    $assert->like(
        $async // '',
        qr/force_grace\s*=>\s*1\.5/,
        'trivia preserves its forced-completion deadline through AsyncWorker'
    );

    $assert->like(
        $worker_src,
        qr/\$self->\{forced\}\s*\|\|.*?\$self->\{child_done\}/s,
        'shared worker retains the liveness backstop'
    );

    $assert->like(
        $worker_src,
        qr/local \$SIG\{TERM\}\s*=\s*'DEFAULT'/,
        'shared forked worker resets inherited TERM handling'
    );

    $assert->like(
        $src,
        qr/last_stage\s*=>\s*'last_stage'/,
        'final command failure log includes the last worker stage'
    );

    $assert->like(
        $src,
        qr/question service request timed out/,
        'hard HTTP timeout has a clear IRC message'
    );

    my $compiled = eval "package MB396::Probe;\n$parse\n$sync\n1;";
    $assert->ok($compiled, 'parser and synchronous worker compile in isolation');

    my @progress;
    my $slow = MB396::HTTP->new(
        sleep_for => 0.30,
        response  => {
            success => 1,
            status  => 200,
            content => '{"response_code":0,"results":[]}',
        },
    );

    my $started = time();
    my $timed = MB396::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $slow,
        hard_timeout => 0.05,
        max_attempts => 1,
        progress_cb  => sub { push @progress, $_[0] },
    );
    my $elapsed = time() - $started;

    $assert->ok(!$timed->{ok}, 'stalled HTTP request is rejected');
    $assert->is($timed->{error}, 'http_timeout', 'stalled request reports http_timeout');
    $assert->is($timed->{stage}, 'http_get', 'stalled request identifies HTTP stage');
    $assert->ok($elapsed < 0.25, 'hard deadline interrupts the blocking test request');
    $assert->ok(
        scalar(grep { ref($_) eq 'HASH' && ($_->{stage} // '') eq 'http_get_start' } @progress),
        'progress includes HTTP request start'
    );
    $assert->ok(
        scalar(grep { ref($_) eq 'HASH' && ($_->{stage} // '') eq 'http_get_timeout' } @progress),
        'progress includes hard HTTP timeout'
    );

    my $ok_json = '{"response_code":0,"results":[{"type":"multiple","difficulty":"easy","category":"General Knowledge","question":"Question?","correct_answer":"Answer","incorrect_answers":["Wrong 1","Wrong 2","Wrong 3"]}]}';
    @progress = ();
    my $fast = MB396::HTTP->new(
        response => {
            success => 1,
            status  => 200,
            headers => { 'content-type' => 'application/json' },
            content => $ok_json,
        },
    );

    my $ok = MB396::Probe::_trivia_fetch_sync(
        undef,
        undef,
        http         => $fast,
        hard_timeout => 0.5,
        max_attempts => 1,
        progress_cb  => sub { push @progress, $_[0] },
    );

    $assert->ok($ok->{ok}, 'fast valid response still succeeds');
    $assert->is($ok->{status}, 200, 'successful HTTP status is preserved');
    $assert->ok(
        scalar(grep { ref($_) eq 'HASH' && ($_->{stage} // '') eq 'http_get_done' } @progress),
        'progress includes HTTP completion metadata'
    );
    $assert->ok(
        scalar(grep { ref($_) eq 'HASH' && ($_->{stage} // '') eq 'api_parse_ok' } @progress),
        'progress includes successful API parsing'
    );
};
