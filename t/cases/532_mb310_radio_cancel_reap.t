# t/cases/532_mb310_radio_cancel_reap.t
# =============================================================================
# MB310:
#   - radio cancellation must keep job state until waitpid reaps the child;
#   - TERM/KILL escalation must remain asynchronous when IO::Async is present;
#   - repeated cancel commands must not create duplicate timers;
#   - status must expose the cancelling phase.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb310 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";

    local $/;
    return <$fh>;
}

sub _extract_sub_mb310 {
    my ($src, $name) = @_;

    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);

        $depth++ if $char eq '{';
        $depth-- if $char eq '}';

        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb310(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $helper = _extract_sub_mb310($src, '_radio_cancel_try_reap');
    my $cancel = _extract_sub_mb310($src, 'radioDlCancel_ctx');
    my $status = _extract_sub_mb310($src, 'radioDlStatus_ctx');

    $assert->ok(
        defined $helper,
        'non-blocking radio child reaper helper found'
    );

    $assert->ok(
        defined $cancel,
        'radioDlCancel_ctx found'
    );

    $assert->ok(
        defined $status,
        'radioDlStatus_ctx found'
    );

    $assert->like(
        $helper // '',
        qr/waitpid\(\$pid,\s*WNOHANG\)/,
        'radio cancellation reaper uses WNOHANG'
    );

    $assert->unlike(
        $cancel // '',
        qr/waitpid\(\$pid,\s*0\)/,
        'radio cancellation never performs an unconditional blocking waitpid'
    );

    $assert->like(
        $cancel // '',
        qr/cancel_reap_timer/,
        'radio cancellation installs a dedicated reap timer'
    );

    $assert->like(
        $cancel // '',
        qr/cancel_kill_timer/,
        'radio cancellation keeps TERM-to-KILL escalation asynchronous'
    );

    $assert->like(
        $cancel // '',
        qr/return\s+if\s+\$job->\{cancel_cleanup_done\}/,
        'radio cancellation cleanup is idempotent'
    );

    $assert->like(
        $cancel // '',
        qr/cancellation already in progress/,
        'repeated cancel commands report existing cancellation instead of duplicating timers'
    );

    $assert->like(
        $cancel // '',
        qr/keep the job state\s*\n\s*# instead of falsely reporting successful cancellation/s,
        'unreaped fallback children keep their active job state'
    );

    $assert->like(
        $status // '',
        qr/\$job->\{cancel_requested\}\s*\?\s*'cancelling'\s*:\s*'active'/,
        'download status distinguishes active and cancelling jobs'
    );

    $assert->like(
        $status // '',
        qr/cancel_phase=\$phase/,
        'download status exposes the TERM/KILL cancellation phase'
    );

    # Exercise the real helper in an isolated process. The first probe must
    # report a running child; after TERM it must eventually report it reaped.
    my $probe = join "\n",
        'use strict;',
        'use warnings;',
        'use POSIX qw(WNOHANG);',
        'use Time::HiRes qw(time sleep);',
        $helper,
        q{
my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    sleep 10;
    exit 0;
}

my ($initial) = _radio_cancel_try_reap($pid);
kill 'TERM', $pid;

my $deadline = time() + 2;
my $final = 'running';

while (time() < $deadline) {
    ($final) = _radio_cancel_try_reap($pid);
    last if $final ne 'running';
    sleep 0.02;
}

my ($invalid) = _radio_cancel_try_reap('not-a-pid');

print join('|', $initial, $final, $invalid), "\n";
},
    ;

    open my $fh, '-|', $^X, '-e', $probe
        or die "could not start MB310 probe: $!";

    local $/;
    my $output = <$fh> // '';
    close $fh;

    my $rc = $? >> 8;
    $output =~ s/\s+\z//;

    $assert->is(
        $rc,
        0,
        'isolated radio child reaper probe exits successfully'
    );

    $assert->is(
        $output,
        'running|reaped|invalid',
        'radio child state remains running until waitpid actually reaps it'
    );
};
