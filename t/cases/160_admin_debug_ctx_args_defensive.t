# t/cases/160_admin_debug_ctx_args_defensive.t
# =============================================================================
# Regression checks for AdminCommands::debug_ctx().
#
# debug_ctx should not assume $ctx->args is always an ARRAY reference.
# The undef-only form @{ $ctx->args // [] } still dies if args is a scalar.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_admin_debug_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_admin_debug_ctx_args {
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

    my $src = _slurp_admin_debug_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_body_admin_debug_ctx_args($src, 'debug_ctx');

    $assert->ok(
        defined $body,
        'debug_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'debug_ctx reads context args defensively'
    );

    $assert->unlike(
        $body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'debug_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $body // '',
        qr/my \$level = \$args\[0\];/,
        'debug_ctx still reads requested debug level from args'
    );

    $assert->like(
        $body // '',
        qr/Current debug level is \$current/,
        'debug_ctx still reports current debug level without args'
    );
};
