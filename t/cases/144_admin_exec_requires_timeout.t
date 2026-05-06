# t/cases/144_admin_exec_requires_timeout.t
# =============================================================================
# Regression checks for AdminCommands::mbExec_ctx().
#
# The Owner-only exec command must never run without a hard timeout guard.
# If /usr/bin/timeout is not available, exec should refuse to run instead of
# falling back to a plain sh -c command that can hang the bot.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_admin_exec_timeout {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_admin_exec_timeout {
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

    my $src = _slurp_admin_exec_timeout(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_body_admin_exec_timeout($src, 'mbExec_ctx');

    $assert->ok(
        defined $body,
        'mbExec_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \$timeout_bin = '\/usr\/bin\/timeout';/,
        'mbExec_ctx defines the timeout binary'
    );

    $assert->like(
        $body // '',
        qr/unless \(-x \$timeout_bin\)/,
        'mbExec_ctx refuses to run when timeout is unavailable'
    );

    $assert->like(
        $body // '',
        qr/refusing to run exec without \$timeout_bin/,
        'mbExec_ctx logs missing timeout refusal'
    );

    $assert->like(
        $body // '',
        qr/Execution unavailable: \$timeout_bin not found\./,
        'mbExec_ctx reports missing timeout to the caller'
    );

    $assert->like(
        $body // '',
        qr/my \@runner = \(\$timeout_bin, '--kill-after=2s', "\$\{exec_timeout\}s", 'sh', '-c', \$shell\);/,
        'mbExec_ctx always runs through /usr/bin/timeout'
    );

    $assert->unlike(
        $body // '',
        qr/:\s*\('sh', '-c', \$shell\)/,
        'mbExec_ctx no longer falls back to plain sh -c without timeout'
    );

    $assert->unlike(
        $body // '',
        qr/my \@runner = \(-x \$timeout_bin\)\s*\?/,
        'mbExec_ctx no longer uses a conditional runner with unsafe fallback'
    );
};
