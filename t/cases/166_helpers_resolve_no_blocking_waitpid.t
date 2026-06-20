# t/cases/166_helpers_resolve_no_blocking_waitpid.t
# =============================================================================
# MB311 regression checks for Helpers::resolve_ctx().
#
# Both forward and reverse DNS run in a child process. Timeout escalation and
# child collection must remain asynchronous so the IRC loop never sleeps or
# blocks in waitpid().
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

    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";

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
        $src,
        qr/^use IO::Async::Stream;$/m,
        'Helpers.pm imports IO::Async::Stream'
    );

    $assert->like(
        $body // '',
        qr/waitpid\(\$child_pid,\s*WNOHANG\)/,
        'resolve_ctx uses non-blocking waitpid'
    );

    $assert->like(
        $body // '',
        qr/kill 'TERM', \$child_pid;/,
        'resolve_ctx sends TERM to a stuck resolver child'
    );

    $assert->like(
        $body // '',
        qr/delay\s*=>\s*0\.2/,
        'resolve_ctx schedules the TERM-to-KILL grace period asynchronously'
    );

    $assert->like(
        $body // '',
        qr/kill 'KILL', \$child_pid;/,
        'resolve_ctx escalates to KILL when the resolver child remains'
    );

    $assert->unlike(
        $body // '',
        qr/(?:sleep|usleep|select)\s*\(/,
        'resolve_ctx does not sleep inside the event loop'
    );

    $assert->unlike(
        $body // '',
        qr/waitpid\(\$child_pid,\s*0\)/,
        'resolve_ctx has no unconditional blocking waitpid'
    );

    $assert->like(
        $body // '',
        qr/IO::Async::Stream->new/,
        'resolve_ctx consumes lookup output asynchronously'
    );
};
