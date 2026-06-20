# t/cases/531_mb309_partyline_eval_nonblocking_reap.t
# =============================================================================
# MB309: Partyline .eval must never block the IRC loop after pipe EOF and must
# report both child- and parent-side timeout paths exactly once.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb309 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb309 {
    my ($src, $name) = @_;
    my $start_re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb309(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );
    my $body = _extract_sub_mb309($src, '_cmd_eval');

    $assert->ok(defined $body, '_cmd_eval body found');
    $assert->unlike($body // '', qr/waitpid\s*\(\s*\$pid\s*,\s*0\s*\)/,
        '.eval no longer performs an unconditional blocking waitpid');
    $assert->like($body // '', qr/waitpid\s*\(\s*\$pid\s*,\s*WNOHANG\s*\)/,
        '.eval reaps the child non-blockingly');
    $assert->like($body // '', qr/\$schedule_reap\s*=\s*sub/,
        '.eval defines a reusable asynchronous reaper');
    $assert->like($body // '', qr/if\s*\(\$eof\s*&&\s*!\$eval_ctx->\{pipe_eof\}\+\+\)/,
        'pipe EOF is handled once');
    $assert->like($body // '', qr/\$schedule_reap->\(\);/,
        'pipe EOF schedules non-blocking process reaping');
    $assert->like($body // '', qr/timeout_reported\s*=>\s*0/,
        'timeout reporting state is tracked');
    $assert->like($body // '', qr/return if \$eval_ctx->\{timeout_reported\}\+\+/,
        'timeout is reported at most once');
    $assert->like($body // '', qr/Preserve a final line that is not newline-terminated/,
        'final partial eval output is preserved');
};
