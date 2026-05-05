# t/cases/95_clean_exit_quit_message_config.t
# =============================================================================
# Regression checks for clean_and_exit() quit message configuration.
#
# The official sample config documents:
#   [main]
#   MAIN_PROG_QUIT_MSG=...
#
# clean_and_exit() must read main.MAIN_PROG_QUIT_MSG, not an undocumented
# top-level IRC_QUIT_MESSAGE key.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_quit_message_config {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_quit_message_config {
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

    my $core = _slurp_quit_message_config(
        File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm')
    );

    my $sample = _slurp_quit_message_config(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $clean = _extract_sub_body_quit_message_config($core, 'clean_and_exit');

    $assert->ok(
        defined $clean,
        'clean_and_exit body found'
    );

    $assert->like(
        $sample,
        qr/^MAIN_PROG_QUIT_MSG=/m,
        'sample config documents main.MAIN_PROG_QUIT_MSG'
    );

    $assert->like(
        $clean,
        qr/get\('main\.MAIN_PROG_QUIT_MSG'\)/,
        'clean_and_exit reads main.MAIN_PROG_QUIT_MSG'
    );

    $assert->unlike(
        $clean,
        qr/get\('IRC_QUIT_MESSAGE'\)/,
        'clean_and_exit does not read undocumented IRC_QUIT_MESSAGE'
    );

    $assert->like(
        $clean,
        qr/my\s+\$quit_msg\s*=\s*"Mediabot shutting down"/,
        'clean_and_exit still has a safe fallback quit message'
    );

    $assert->like(
        $clean,
        qr/\$quit_msg\s*=\s*\$cfg\s+if\s+defined\(\$cfg\)\s+&&\s+\$cfg\s+ne\s+''/,
        'configured quit message overrides fallback when non-empty'
    );
};
