# t/cases/140_external_chromium_timeout_kill_escalation.t
# =============================================================================
# Regression checks for Chromium dump-dom timeout cleanup.
#
# If Chromium times out, TERM followed by a blocking waitpid() can still hang
# if the child ignores TERM. The cleanup path should use WNOHANG, wait briefly,
# then escalate to KILL if needed.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_external_chromium_timeout {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_external_chromium_timeout {
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

    my $src = _slurp_external_chromium_timeout(
        File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm')
    );

    my $body = _extract_sub_body_external_chromium_timeout($src, '_fetch_url_chromium_dumpdom');

    $assert->ok(
        defined $body,
        '_fetch_url_chromium_dumpdom body found'
    );

    $assert->like(
        $src,
        qr/^use POSIX qw\(WNOHANG\);$/m,
        'External/URL.pm imports WNOHANG'
    );

    $assert->like(
        $body // '',
        qr/eval \{ kill 'TERM', \$pid \};/,
        'timeout cleanup sends TERM first'
    );

    $assert->like(
        $body // '',
        qr/waitpid\(\$pid, WNOHANG\)/,
        'timeout cleanup uses non-blocking waitpid after TERM'
    );

    $assert->like(
        $body // '',
        qr/usleep\(200_000\);/,
        'timeout cleanup waits briefly between TERM and KILL checks'
    );

    $assert->like(
        $body // '',
        qr/eval \{ kill 'KILL', \$pid \};/,
        'timeout cleanup escalates to KILL if the child remains'
    );

    $assert->unlike(
        $body // '',
        qr/eval \{ kill 'TERM', \$pid \};\s*waitpid\(\$pid, 0\);/,
        'timeout cleanup no longer blocks immediately after TERM'
    );
};
