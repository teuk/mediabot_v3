# t/cases/207_helpers_http_guard_regression.t
# =============================================================================
# Regression checks for raw HTTP::Tiny calls in Mediabot::Helpers.
#
# Helpers.pm has a couple of legacy utility HTTP calls. They must be protected
# with eval so DNS/SSL/network exceptions do not crash command execution.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_207 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_207 {
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

    my $src = _slurp_207(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $check_version = _extract_sub_207($src, 'getVersion');
    my $whereis       = _extract_sub_207($src, 'whereis');

    $assert->ok(
        defined $check_version && $check_version ne '',
        'getVersion body found'
    );

    $assert->ok(
        defined $whereis && $whereis ne '',
        'whereis body found'
    );

    $assert->like(
        $check_version // '',
        qr/my\s+\$response\s*=\s*eval\s+\{\s*HTTP::Tiny->new\(timeout\s*=>\s*5\)->get\(\$version_url\);\s*\}/,
        'getVersion protects GitHub VERSION fetch with eval'
    );

    $assert->like(
        $whereis // '',
        qr/my\s+\$response\s*=\s*eval\s+\{\s*HTTP::Tiny->new\(timeout\s*=>\s*3\)->get\(\$whereis_url\);\s*\}/,
        'whereis protects country.is fetch with eval'
    );

    $assert->like(
        $check_version // '',
        qr/reason\s*=>\s*\$\@/,
        'getVersion keeps network exception reason in fallback response'
    );

    $assert->like(
        $whereis // '',
        qr/reason\s*=>\s*\$\@/,
        'whereis keeps network exception reason in fallback response'
    );

    $assert->unlike(
        $check_version // '',
        qr/my\s+\$response\s*=\s*HTTP::Tiny->new\(timeout\s*=>\s*5\)->get\(\$version_url\);/,
        'getVersion no longer calls HTTP without eval'
    );

    $assert->unlike(
        $whereis // '',
        qr/my\s+\$response\s*=\s*HTTP::Tiny->new\(timeout\s*=>\s*3\)->get\(\$whereis_url\);/,
        'whereis no longer calls HTTP without eval'
    );
};
