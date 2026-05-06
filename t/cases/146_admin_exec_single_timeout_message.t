# t/cases/146_admin_exec_single_timeout_message.t
# =============================================================================
# Regression checks for AdminCommands::mbExec_ctx().
#
# The exec timeout branch should report the timeout to the caller once, not
# duplicate the same line.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_admin_exec_timeout_message {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_admin_exec_timeout_message {
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

    my $src = _slurp_admin_exec_timeout_message(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_body_admin_exec_timeout_message($src, 'mbExec_ctx');

    $assert->ok(
        defined $body,
        'mbExec_ctx body found'
    );

    my $timeout_msg_count = () = ($body // '') =~ /\$send->\("Command timed out after \$\{exec_timeout\}s\."\);/g;

    $assert->is(
        $timeout_msg_count,
        1,
        'mbExec_ctx sends the exec timeout message exactly once'
    );

    $assert->like(
        $body // '',
        qr/\$exit_status == 124 \|\| \$exit_status == 137/,
        'mbExec_ctx still recognizes timeout exit statuses'
    );

    $assert->like(
        $body // '',
        qr/mbExec_ctx: command timed out after \$\{exec_timeout\}s: \$command/,
        'mbExec_ctx still logs timeout details'
    );

    $assert->like(
        $body // '',
        qr/my \@runner = \(\$timeout_bin, '--kill-after=2s', "\$\{exec_timeout\}s", 'sh', '-c', \$shell\);/,
        'mbExec_ctx still runs commands through /usr/bin/timeout'
    );
};
