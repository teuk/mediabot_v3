# t/cases/823_mb643_version_worker_pipe_fork_liveness.t
# =============================================================================
# mb643/mb652 — explicit pipe/fork and liveness guarantees remain mandatory,
# but MB652 centralises those mechanics in Mediabot::AsyncWorker.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_823 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $hsrc = _slurp_823('Mediabot/Helpers.pm');
    my $awsrc = _slurp_823('Mediabot/AsyncWorker.pm');
    my ($async) = $hsrc =~ /(sub getVersion_async \{.*?\n\}\n# getDetailedVersion)/s;

    $assert->ok(defined $async, 'mb652-823: getVersion_async localisee');

    $assert->like($async // '',
        qr/shared AsyncWorker owns pipe\/fork.*?timeout escalation.*?callback-once/s,
        'mb652-823: delegation rationale is documented');

    $assert->like($async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'mb652-823: version adapter starts shared worker');

    my $exec = $async // '';
    $exec =~ s/#.*$//mg;
    $assert->unlike($exec, qr/\bpipe\s*\(/,
        'mb652-823: version adapter no longer duplicates pipe setup');
    $assert->unlike($exec, qr/\bfork\s*\(/,
        'mb652-823: version adapter no longer duplicates fork');
    $assert->unlike($exec, qr/\bwaitpid\s*\(/,
        'mb643-823: version adapter has no manual reap');
    $assert->unlike($exec, qr/\bkill\s+['"](?:TERM|KILL)['"]/,
        'mb652-823: version adapter no longer owns TERM/KILL');

    $assert->like($awsrc,
        qr/\bpipe\(\$read_fh,\s*\$write_fh\).*?\bmy \$pid = fork\(\)/s,
        'mb643-823: shared worker uses explicit pipe + fork');
    $assert->unlike($awsrc,
        qr/open\s*\([^;\n]*['"]-\|['"]/,
        'mb643-823: shared worker never uses piped-open');
    $assert->like($awsrc,
        qr/binmode\(\$write_fh,\s*':raw'\)/,
        'mb643-823: shared child uses dedicated raw writer');
    $assert->like($awsrc,
        qr/_write_all\(\$write_fh,\s*\$payload\)/,
        'mb652-823: shared child writes JSON only to dedicated pipe');
    $assert->like($awsrc,
        qr/POSIX::_exit\(0\)/,
        'mb643-823: shared child exits without inherited destructors');
    $assert->like($awsrc,
        qr/->watch_process\(\s*\$pid,/s,
        'mb643-823: IO::Async remains process owner');
    $assert->like($awsrc,
        qr/\$self->\{forced\}\s*\|\|.*?\$self->\{child_done\}/s,
        'mb643-823: liveness backstop remains part of finalization');
    $assert->like($awsrc,
        qr/for my \$name \(qw\(timeout_timer kill_timer force_timer\)\)/,
        'mb643-823: all lifecycle timers are cleaned centrally');
    $assert->like($awsrc,
        qr/\$self->_signal_child\('TERM'\).*?_signal_child\('KILL'\)/s,
        'mb643-823: shared timeout path preserves TERM then KILL');
    $assert->like($awsrc,
        qr/return 0 if \$self->\{finalized\}/,
        'mb643-823: shared completion protects callback-once semantics');

    $assert->like($async // '',
        qr/term_grace\s*=>\s*0\.2.*?force_grace\s*=>\s*2/s,
        'mb652-823: version-specific escalation timings are preserved');
    $assert->like($async // '',
        qr/max_output\s*=>\s*1024/,
        'mb652-823: version-specific output bound is preserved');
};
