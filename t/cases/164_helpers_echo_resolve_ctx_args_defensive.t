# t/cases/164_helpers_echo_resolve_ctx_args_defensive.t
# =============================================================================
# Regression checks for Helpers context argument handling.
#
# mbEcho() and resolve_ctx() should not assume $ctx->args is always an ARRAY
# reference. The undef-only form @{ $ctx->args // [] } still dies if args is a
# scalar or another non-ARRAY value.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_helpers_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_helpers_ctx_args {
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

    my $src = _slurp_helpers_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $echo_body    = _extract_sub_body_helpers_ctx_args($src, 'mbEcho');
    my $resolve_body = _extract_sub_body_helpers_ctx_args($src, 'resolve_ctx');

    $assert->ok(
        defined $echo_body,
        'mbEcho body found'
    );

    $assert->ok(
        defined $resolve_body,
        'resolve_ctx body found'
    );

    $assert->like(
        $echo_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'mbEcho reads context args defensively'
    );

    $assert->like(
        $echo_body // '',
        qr/my \$text = join\(' ', \@args\);/,
        'mbEcho still builds text from args'
    );

    $assert->unlike(
        $echo_body // '',
        qr/join\(' ', \@\{ \$ctx->args \/\/ \[\] \}\)/,
        'mbEcho no longer uses undef-only args fallback'
    );

    $assert->like(
        $resolve_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'resolve_ctx reads context args defensively'
    );

    $assert->unlike(
        $resolve_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'resolve_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $resolve_body // '',
        qr/Syntax: resolve <hostname\|IP>/,
        'resolve_ctx still keeps its syntax message'
    );
};
