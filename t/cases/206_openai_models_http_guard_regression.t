# t/cases/206_openai_models_http_guard_regression.t
# =============================================================================
# Regression checks for OpenAI models command HTTP guard.
#
# The "openai models" admin command must not call HTTP directly without eval.
# Network/SSL/DNS failures should become a clean notice, not a crash.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_206 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_206 {
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

    my $src = _slurp_206(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_206($src, '_openai_notice_models');

    $assert->ok(
        defined $body && $body ne '',
        '_openai_notice_models body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$res\s+=\s+eval\s+\{/,
        '_openai_notice_models protects HTTP GET with eval'
    );

    $assert->like(
        $body // '',
        qr/\$http->get\(\s*\$models_url,/,
        '_openai_notice_models still queries the models endpoint'
    );

    $assert->like(
        $body // '',
        qr/reason\s*=>\s*\$\@/,
        '_openai_notice_models records literal $@ in fallback error structure'
    );

    $assert->like(
        $body // '',
        qr/OpenAI models: HTTP \$status \$reason/,
        '_openai_notice_models reports HTTP/network errors cleanly'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\$res\s+=\s+\$http->get\(/,
        '_openai_notice_models no longer calls HTTP GET without eval'
    );
};
