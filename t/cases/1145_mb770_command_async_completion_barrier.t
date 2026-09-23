# MB770 R6 — CommandAsync consumes the result pipe before finalizing.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

sub _slurp_1145 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    require Mediabot::CommandAsync;

    my $process_first = {
        finalized => 0, process_done => 0, pipe_eof => 0,
    };
    my $process_first_calls = 0;
    my $process_first_finalize = sub {
        $process_first_calls++;
        $process_first->{finalized} = 1;
    };

    $process_first->{process_done} = 1;
    $assert->is(
        Mediabot::CommandAsync::_worker_completion_barrier(
            $process_first, $process_first_finalize),
        0,
        'process exit alone does not finalize before pipe EOF');
    $assert->is($process_first_calls, 0,
        'process-first ordering preserves the unread result');

    $process_first->{pipe_eof} = 1;
    $assert->is(
        Mediabot::CommandAsync::_worker_completion_barrier(
            $process_first, $process_first_finalize),
        1,
        'pipe EOF releases a process-first completion');
    $assert->is($process_first_calls, 1,
        'process-first completion finalizes exactly once');
    $assert->is(
        Mediabot::CommandAsync::_worker_completion_barrier(
            $process_first, $process_first_finalize),
        0,
        'a completed worker cannot finalize twice');

    my $eof_first = {
        finalized => 0, process_done => 0, pipe_eof => 1,
    };
    my $eof_first_calls = 0;
    my $eof_first_finalize = sub {
        $eof_first_calls++;
        $eof_first->{finalized} = 1;
    };

    $assert->is(
        Mediabot::CommandAsync::_worker_completion_barrier(
            $eof_first, $eof_first_finalize),
        0,
        'pipe EOF alone waits for the process reap');
    $eof_first->{process_done} = 1;
    $assert->is(
        Mediabot::CommandAsync::_worker_completion_barrier(
            $eof_first, $eof_first_finalize),
        1,
        'process reap releases an EOF-first completion');
    $assert->is($eof_first_calls, 1,
        'EOF-first completion finalizes exactly once');

    my $source = _slurp_1145('Mediabot/CommandAsync.pm');
    $assert->like($source,
        qr/on_read_eof\s*=>\s*sub\s*\{\s*\$state->\{pipe_eof\}\s*=\s*1;\s*\$completion_barrier->\(\)/s,
        'runtime marks pipe EOF before consulting the barrier');
    $assert->like($source,
        qr/watch_process\(\$pid,\s*sub\s*\{\s*\$state->\{process_done\}\s*=\s*1;\s*\$completion_barrier->\(\)/s,
        'runtime marks process completion before consulting the barrier');
    $assert->ok($source !~ /watch_process\(\$pid,\s*sub\s*\{\s*\$finalize->\(\)/s,
        'watch_process no longer bypasses unread pipe data');
};
