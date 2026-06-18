# t/cases/210_tmdb_final_message_truncate_regression.t
# =============================================================================
# Regression checks for TMDB final message truncation.
#
# The IRC line should be built first and then truncated as a complete message.
# This avoids negative/odd overview budgets when the prefix is long or
# MAIN_PROG_MAXLEN is small.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_210 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_210 {
    my ($src, $sub_name) = @_;

    my $re = qr/^[ \t]*sub[ \t]+\Q$sub_name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < $len) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
                $pos++;
                next;
            }

            if ($ch eq "\\") {
                $escape = 1;
                $pos++;
                next;
            }

            if ($ch eq $quote) {
                undef $quote;
                $pos++;
                next;
            }

            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
            $pos++;
            next;
        }

        if ($ch eq '"' || $ch eq "'") {
            $quote = $ch;
            $pos++;
            next;
        }

        if ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos + 1 - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_210(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $body = _extract_sub_210($src, 'mbTMDBSearch_ctx');

    $assert->ok(
        defined $body && $body ne '',
        'mbTMDBSearch_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$reply\s+=\s+\$prefix\s+\.\s+\$overview;/,
        'TMDB builds final reply before truncation'
    );

    $assert->like(
        $body // '',
        qr/\$maxlen\s+=\s+120\s+if\s+\$maxlen\s+<\s+120;/,
        'TMDB clamps MAIN_PROG_MAXLEN to a safe minimum'
    );

    $assert->like(
        $body // '',
        qr/\$maxlen\s+=\s+900\s+if\s+\$maxlen\s+>\s+900;/,
        'TMDB clamps MAIN_PROG_MAXLEN to a sane maximum'
    );

    $assert->like(
        $body // '',
        qr/if\s+\(length\(\$reply\)\s+>\s+\$maxlen\)/,
        'TMDB truncates the full final reply'
    );

    $assert->like(
        $body // '',
        qr/botPrivmsg\(\$self,\s*\$channel,\s*\$reply\);/,
        'TMDB sends the final truncated reply'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\$overview_max\s+=\s+\$maxlen\s+-\s+length\(\$prefix\)\s+-\s+4;/,
        'TMDB no longer uses negative-prone overview_max calculation'
    );

    $assert->unlike(
        $body // '',
        qr/botPrivmsg\(\$self,\s*\$channel,\s*\$prefix\s+\.\s+\$overview\);/,
        'TMDB no longer sends unbounded prefix + overview directly'
    );
};
