# t/cases/162_logincommands_userpass_userident_ctx_args.t
# =============================================================================
# Regression checks for LoginCommands context argument handling.
#
# userPass_ctx() and userIdent_ctx() should not assume $ctx->args is always an
# ARRAY reference. They should pass an empty list when args is missing or invalid.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_logincommands_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_logincommands_ctx_args {
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

    my $src = _slurp_logincommands_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'LoginCommands.pm')
    );

    my $pass_body  = _extract_sub_body_logincommands_ctx_args($src, 'userPass_ctx');
    my $ident_body = _extract_sub_body_logincommands_ctx_args($src, 'userIdent_ctx');

    $assert->ok(
        defined $pass_body,
        'userPass_ctx body found'
    );

    $assert->ok(
        defined $ident_body,
        'userIdent_ctx body found'
    );

    $assert->like(
        $pass_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'userPass_ctx reads context args defensively'
    );

    $assert->like(
        $pass_body // '',
        qr/userPass\(\$ctx->bot, \$ctx->message, \$ctx->nick, \@args\);/,
        'userPass_ctx forwards safe args'
    );

    $assert->unlike(
        $pass_body // '',
        qr/userPass\(\$ctx->bot, \$ctx->message, \$ctx->nick, \@\{ \$ctx->args \}\);/,
        'userPass_ctx no longer blindly dereferences ctx args'
    );

    $assert->like(
        $ident_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'userIdent_ctx reads context args defensively'
    );

    $assert->like(
        $ident_body // '',
        qr/userIdent\(\$ctx->bot, \$ctx->message, \$ctx->nick, \@args\);/,
        'userIdent_ctx forwards safe args'
    );

    $assert->unlike(
        $ident_body // '',
        qr/userIdent\(\$ctx->bot, \$ctx->message, \$ctx->nick, \@\{ \$ctx->args \}\);/,
        'userIdent_ctx no longer blindly dereferences ctx args'
    );
};
