# t/cases/105_partyline_eval_enabled_guard.t
# =============================================================================
# Regression checks for Partyline .eval safety.
#
# .eval is dangerous. Owner level is necessary, but not sufficient:
# it must also be explicitly enabled through:
#
#   [main]
#   PARTYLINE_EVAL_ENABLED=1
#
# The sample config keeps it disabled by default.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_partyline_eval_guard {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_partyline_eval_guard {
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

    my $partyline = _slurp_partyline_eval_guard(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    my $sample = _slurp_partyline_eval_guard(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $body = _extract_sub_body_partyline_eval_guard($partyline, '_cmd_eval');

    $assert->ok(
        defined $body,
        '_cmd_eval body found'
    );

    $assert->like(
        $sample,
        qr/^PARTYLINE_EVAL_ENABLED=0$/m,
        'sample config disables partyline eval by default'
    );

    $assert->like(
        $sample,
        qr/^PARTYLINE_EVAL_TIMEOUT_SECONDS=5$/m,
        'sample config documents partyline eval timeout'
    );

    $assert->like(
        $body // '',
        qr/get\('main\.PARTYLINE_EVAL_ENABLED'\)/,
        '_cmd_eval reads main.PARTYLINE_EVAL_ENABLED'
    );

    $assert->like(
        $body // '',
        qr/Access denied: \.eval is disabled by configuration\./,
        '_cmd_eval refuses execution when disabled by config'
    );

    $assert->like(
        $body // '',
        qr/Set PARTYLINE_EVAL_ENABLED=1 in \[main\] to enable it\./,
        '_cmd_eval tells admins how to enable it explicitly'
    );

    $assert->ok(
        index($body // '', '$eval_enabled =~ /^(?:1|yes|true|on)$/i') >= 0,
        '_cmd_eval accepts explicit truthy values only'
    );

    $assert->like(
        $body // '',
        qr/get\('main\.PARTYLINE_EVAL_TIMEOUT_SECONDS'\)/,
        '_cmd_eval still reads main.PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );

    $assert->like(
        $body // '',
        qr/Access denied: \.eval requires Owner level\./,
        '_cmd_eval still requires Owner level'
    );
};
