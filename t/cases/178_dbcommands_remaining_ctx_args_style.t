# t/cases/178_dbcommands_remaining_ctx_args_style.t
# =============================================================================
# Regression checks for DBCommands context argument handling.
#
# DBCommands should use the same explicit args pattern as the rest of the code:
#
#   my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
#
# This keeps wrapper behavior aligned with Mediabot::Context->args().
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_178 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_178 {
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

    my $src = _slurp_178(
        File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm')
    );

    my @subs = qw(
        addResponder_ctx
        delResponder_ctx
        lastCom_ctx
        Yomomma_ctx
    );

    for my $sub (@subs) {
        my $body = _extract_sub_body_178($src, $sub);

        $assert->ok(
            defined $body,
            "$sub body found"
        );

        $assert->like(
            $body // '',
            qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
            "$sub uses standard ctx->args ARRAY pattern"
        );
    }

    $assert->unlike(
        $src,
        qr/ref \$ctx->args eq 'ARRAY'/,
        'DBCommands.pm no longer uses unparenthesized ref ctx->args checks'
    );

    $assert->unlike(
        $src,
        qr/\@args = \@\{ \$ctx->args \} if ref\(\$ctx->args\) eq 'ARRAY';/,
        'DBCommands.pm no longer uses two-step Yomomma args initialization'
    );
};
