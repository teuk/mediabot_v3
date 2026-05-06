# t/cases/165_logincommands_userlogin_ctx_args_defensive.t
# =============================================================================
# Regression checks for LoginCommands::userLogin_ctx().
#
# userLogin_ctx() should not assume $ctx->args is always an ARRAY reference.
# The undef-only form @{ $ctx->args // [] } still dies if args is a scalar or
# another non-ARRAY value.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_login_userlogin_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_login_userlogin_ctx_args {
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

    my $src = _slurp_login_userlogin_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $body = _extract_sub_body_login_userlogin_ctx_args($src, 'userLogin_ctx');

    $assert->ok(
        defined $body,
        'userLogin_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my \@tArgs\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'userLogin_ctx reads context args defensively'
    );

    $assert->unlike(
        $body // '',
        qr/my \@tArgs\s+= \@\{ \$ctx->args \/\/ \[\] \};/,
        'userLogin_ctx no longer uses undef-only args fallback'
    );

    $assert->like(
        $body // '',
        qr/shift \@tArgs;/,
        'userLogin_ctx still removes injected caller nick when present'
    );

    $assert->like(
        $body // '',
        qr/login <username> <password>/,
        'userLogin_ctx still keeps its login syntax message'
    );

    $assert->like(
        $body // '',
        qr/my \$max_fail = 5;/,
        'userLogin_ctx still keeps brute-force throttle logic'
    );
};
