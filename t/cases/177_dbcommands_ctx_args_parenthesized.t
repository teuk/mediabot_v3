# t/cases/177_dbcommands_ctx_args_parenthesized.t
# =============================================================================
# Regression checks for DBCommands context argument handling.
#
# DBCommands wrappers should use the same explicit ctx->args ARRAY check as the
# rest of the command wrappers:
#
#   ref($ctx->args) eq 'ARRAY'
#
# rather than the older unparenthesized form.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_177 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_177 {
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

    my $src = _slurp_177(
        File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm')
    );

    my $add_body  = _extract_sub_body_177($src, 'addResponder_ctx');
    my $del_body  = _extract_sub_body_177($src, 'delResponder_ctx');
    my $last_body = _extract_sub_body_177($src, 'lastCom_ctx');

    $assert->ok(defined $add_body,  'addResponder_ctx body found');
    $assert->ok(defined $del_body,  'delResponder_ctx body found');
    $assert->ok(defined $last_body, 'lastCom_ctx body found');

    $assert->like(
        $add_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'addResponder_ctx uses parenthesized ctx->args ARRAY check'
    );

    $assert->like(
        $del_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'delResponder_ctx uses parenthesized ctx->args ARRAY check'
    );

    $assert->like(
        $last_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'lastCom_ctx uses parenthesized ctx->args ARRAY check'
    );

    $assert->unlike(
        $src,
        qr/ref \$ctx->args eq 'ARRAY'/,
        'DBCommands.pm no longer uses unparenthesized ref $ctx->args checks'
    );
};
