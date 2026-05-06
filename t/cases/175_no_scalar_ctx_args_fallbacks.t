# t/cases/175_no_scalar_ctx_args_fallbacks.t
# =============================================================================
# Regression checks for remaining context argument wrappers.
#
# Command wrappers should accept args only when $ctx->args is an ARRAY
# reference. A scalar ctx->args should not be converted into a valid argument
# list by accident.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_175 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_175 {
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

    my $hailo_src = _slurp_175(
        File::Spec->catfile('.', 'Mediabot', 'Hailo.pm')
    );

    my $helpers_src = _slurp_175(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $hailo_body = _extract_sub_body_175($hailo_src, 'hailo_chatter_ctx');
    my $where_body = _extract_sub_body_175($helpers_src, 'mbWhereis_ctx');

    $assert->ok(defined $hailo_body, 'hailo_chatter_ctx body found');
    $assert->ok(defined $where_body, 'mbWhereis_ctx body found');

    $assert->like(
        $hailo_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'hailo_chatter_ctx accepts only ARRAY context args'
    );

    $assert->like(
        $where_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'mbWhereis_ctx accepts only ARRAY context args'
    );

    $assert->unlike(
        $hailo_body // '',
        qr/elsif \(defined \$ctx->args\)/,
        'hailo_chatter_ctx no longer has scalar ctx->args fallback'
    );

    $assert->unlike(
        $where_body // '',
        qr/elsif \(defined \$ctx->args\)/,
        'mbWhereis_ctx no longer has scalar ctx->args fallback'
    );

    $assert->unlike(
        $hailo_body // '',
        qr/\@args = \(\$ctx->args\);/,
        'hailo_chatter_ctx no longer converts scalar ctx->args into one argument'
    );

    $assert->unlike(
        $where_body // '',
        qr/\@args = \(\$ctx->args\);/,
        'mbWhereis_ctx no longer converts scalar ctx->args into one argument'
    );

    $assert->like(
        $hailo_body // '',
        qr/hailo_chatter/,
        'hailo_chatter_ctx still contains hailo_chatter logic'
    );

    $assert->like(
        $where_body // '',
        qr/Syntax: whereis <nick>/,
        'mbWhereis_ctx still keeps its syntax message'
    );
};
