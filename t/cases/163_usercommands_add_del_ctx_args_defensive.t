# t/cases/163_usercommands_add_del_ctx_args_defensive.t
# =============================================================================
# Regression checks for UserCommands context argument handling.
#
# addUser_ctx() and delUser_ctx() should not assume $ctx->args is always an
# ARRAY reference. The undef-only form @{ $ctx->args // [] } still dies if args
# is a scalar or another non-ARRAY value.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_usercommands_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_usercommands_ctx_args {
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

    my $src = _slurp_usercommands_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $add_body = _extract_sub_body_usercommands_ctx_args($src, 'addUser_ctx');
    my $del_body = _extract_sub_body_usercommands_ctx_args($src, 'delUser_ctx');

    $assert->ok(
        defined $add_body,
        'addUser_ctx body found'
    );

    $assert->ok(
        defined $del_body,
        'delUser_ctx body found'
    );

    $assert->like(
        $add_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'addUser_ctx reads context args defensively'
    );

    $assert->unlike(
        $add_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'addUser_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $add_body // '',
        qr/my \(\$name, \$mask, \$level\) = \@args;/,
        'addUser_ctx still extracts name, mask and level from args'
    );

    $assert->like(
        $del_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'delUser_ctx reads context args defensively'
    );

    $assert->unlike(
        $del_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'delUser_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $del_body // '',
        qr/shift \@args if \@args && lc\(\$args\[0\]\) eq lc\(\$nick\);/,
        'delUser_ctx still removes injected caller nick when present'
    );
};
