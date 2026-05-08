# t/cases/208_chatgpt_http_guard_debug5_regression.t
# =============================================================================
# Regression checks for chatGPT() HTTP guard and verbose logging level.
#
# chatGPT() must not let HTTP::Tiny request exceptions escape. Large/sensitive
# payload-ish logs belong to DEBUG5, not DEBUG3/4.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_208 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_208 {
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

    my $src = _slurp_208(
        File::Spec->catfile('.', 'Mediabot', 'External.pm')
    );

    my $body = _extract_sub_208($src, 'chatGPT');

    $assert->ok(
        defined $body && $body ne '',
        'chatGPT body found'
    );

    $assert->like(
        $body // '',
        qr/return\s+eval\s+\{\s*\$http->request\(/,
        'chatGPT HTTP request is protected by eval'
    );

    $assert->like(
        $body // '',
        qr/reason\s*=>\s*\$\@/,
        'chatGPT fallback response keeps literal $@ exception reason'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{logger\}->log\(\s*5\s*,\s*"chatGPT\(\) chatGPT prompt: \$prompt"\s*\);/,
        'chatGPT prompt is DEBUG5'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{logger\}->log\(\s*5\s*,\s*"chatGPT\(\) Raw API response: \$response"\s*\);/,
        'chatGPT raw API response is DEBUG5'
    );

    $assert->like(
        $body // '',
        qr/\$self->\{logger\}->log\(\s*5\s*,\s*"chatGPT\(\) chatGPT raw answer: \$answer"\s*\);/,
        'chatGPT raw answer is DEBUG5'
    );

    $assert->unlike(
        $body // '',
        qr/return\s+\$http->request\(/,
        'chatGPT no longer returns raw HTTP request without eval'
    );

    $assert->unlike(
        $body // '',
        qr/log\(\s*4\s*,\s*"chatGPT\(\) chatGPT prompt:/,
        'chatGPT prompt is no longer DEBUG4'
    );

    $assert->unlike(
        $body // '',
        qr/log\(\s*4\s*,\s*"chatGPT\(\) chatGPT raw answer:/,
        'chatGPT raw answer is no longer DEBUG4'
    );

    $assert->unlike(
        $body // '',
        qr/log\(\s*3\s*,\s*"chatGPT\(\) Raw API response:/,
        'chatGPT raw API response is no longer DEBUG3'
    );
};
