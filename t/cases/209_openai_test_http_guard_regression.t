# t/cases/209_openai_test_http_guard_regression.t
# =============================================================================
# Regression checks for "openai test" HTTP guard.
#
# _openai_run_test() must not call HTTP::Tiny->post directly without a local
# eval fallback. The caller-level eval is kept, but the HTTP wrapper itself
# should always return a response-like hash.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_209 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_209 {
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

    my $src = _slurp_209(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $body = _extract_sub_209($src, '_openai_run_test');

    $assert->ok(
        defined $body && $body ne '',
        '_openai_run_test body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$send_test\s*=\s*sub\s*\{/,
        '_openai_run_test has send_test wrapper'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$res\s*=\s*eval\s+\{\s*\$http->post\(/,
        'openai test HTTP POST is protected by eval'
    );

    $assert->like(
        $body // '',
        qr/reason\s*=>\s*\$\@/,
        'openai test fallback response keeps literal $@ exception reason'
    );

    $assert->like(
        $body // '',
        qr/OpenAI test: network error:/,
        'openai test still reports primary network error'
    );

    $assert->like(
        $body // '',
        qr/OpenAI test: network error on fallback:/,
        'openai test still reports fallback network error'
    );

    $assert->unlike(
        $body // '',
        qr/my\s+\$res\s*=\s*\$http->post\(/,
        'openai test no longer calls HTTP POST without local eval'
    );
};
