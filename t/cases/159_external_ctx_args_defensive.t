# t/cases/159_external_ctx_args_defensive.t
# =============================================================================
# Regression checks for context argument handling in Mediabot::External.
#
# Command wrappers should not assume $ctx->args is always an ARRAY reference.
# Most wrappers already guard this; chatGPT_ctx() and mbTMDBSearch_ctx() should
# follow the same defensive pattern.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_external_ctx_args {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_external_ctx_args {
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

    my $src = _slurp_external_ctx_args(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $chatgpt_body = _extract_sub_body_external_ctx_args($src, 'chatGPT_ctx');
    my $tmdb_body    = _extract_sub_body_external_ctx_args($src, 'mbTMDBSearch_ctx');

    $assert->ok(
        defined $chatgpt_body,
        'chatGPT_ctx body found'
    );

    $assert->ok(
        defined $tmdb_body,
        'mbTMDBSearch_ctx body found'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/my \@args\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'chatGPT_ctx reads context args defensively'
    );

    $assert->like(
        $tmdb_body // '',
        qr/my \@tArgs\s+= \(ref\(\$ctx->args\) eq 'ARRAY'\) \? \@\{ \$ctx->args \} : \(\);/,
        'mbTMDBSearch_ctx reads context args defensively'
    );

    $assert->unlike(
        $chatgpt_body // '',
        qr/my \@args\s+= \@\{ \$ctx->args \};/,
        'chatGPT_ctx no longer blindly dereferences ctx args'
    );

    $assert->unlike(
        $tmdb_body // '',
        qr/my \@tArgs\s+= \@\{ \$ctx->args \};/,
        'mbTMDBSearch_ctx no longer blindly dereferences ctx args'
    );

    $assert->like(
        $chatgpt_body // '',
        qr/chatGPT\(\$self, \$message, \$nick, \$channel, \@args\);/,
        'chatGPT_ctx still forwards args to chatGPT'
    );

    $assert->like(
        $tmdb_body // '',
        qr/my \$query = join\(" ", \@tArgs\);/,
        'mbTMDBSearch_ctx still builds the TMDB query from args'
    );
};
