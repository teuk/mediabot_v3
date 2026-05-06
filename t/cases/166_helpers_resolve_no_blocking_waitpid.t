# t/cases/166_helpers_resolve_no_blocking_waitpid.t
# =============================================================================
# Regression checks for Helpers::resolve_ctx().
#
# resolve_ctx() spawns a child process for potentially blocking DNS lookups.
# The parent timeout path must not block on waitpid($pid, 0) if the child is
# still stuck. It should use WNOHANG and escalate TERM/KILL if needed.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_helpers_resolve_waitpid {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_helpers_resolve_waitpid {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_helpers_resolve_waitpid(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $body = _extract_sub_body_helpers_resolve_waitpid($src, 'resolve_ctx');

    $assert->ok(
        defined $body,
        'resolve_ctx body found'
    );

    $assert->like(
        $src,
        qr/^use POSIX qw\(strftime WNOHANG\);$/m,
        'Helpers.pm imports WNOHANG'
    );

    $assert->like(
        $body // '',
        qr/waitpid\(\$child_pid, WNOHANG\)/,
        'resolve_ctx uses non-blocking waitpid'
    );

    $assert->like(
        $body // '',
        qr/kill 'TERM', \$child_pid;/,
        'resolve_ctx sends TERM to stuck resolver child'
    );

    $assert->like(
        $body // '',
        qr/select\(undef, undef, undef, 0\.2\);/,
        'resolve_ctx waits briefly after TERM'
    );

    $assert->like(
        $body // '',
        qr/kill 'KILL', \$child_pid;/,
        'resolve_ctx escalates to KILL when resolver child remains'
    );

    $assert->unlike(
        $body // '',
        qr/waitpid\(\$child_pid, 0\) if \$child_pid;/,
        'resolve_ctx no longer blocks immediately on waitpid after timeout'
    );

    $assert->like(
        $body // '',
        qr/IO::Async::Timer::Countdown->new/,
        'resolve_ctx still uses an async timer for DNS lookup collection'
    );
};
