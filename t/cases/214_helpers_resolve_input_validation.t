# t/cases/214_helpers_resolve_input_validation.t
# =============================================================================
# Regression checks for Helpers::resolve_ctx() input validation.
#
# resolve_ctx() spawns a child process for hostname resolution. The call is not
# shell-based, but malformed input should still be rejected before spawning the
# child resolver.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_214 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_214 {
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

    my $src = _slurp_214(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $body = _extract_sub_214($src, 'resolve_ctx');

    $assert->ok(
        defined $body && $body ne '',
        'resolve_ctx body found'
    );

    $assert->like(
        $body // '',
        qr/\$input\s*=~\s*s\/\^\\s\+\|\\s\+\$\/\/g;/,
        'resolve_ctx trims input'
    );

    $assert->like(
        $body // '',
        qr/length\(\$input\)\s*>\s*253/,
        'resolve_ctx rejects overlong hostnames before fork'
    );

    $assert->like(
        $body // '',
        qr/my\s+\@octets\s*=\s*split\s+\/\\\.\/,\s*\$input;/,
        'resolve_ctx splits IPv4 octets'
    );

    $assert->like(
        $body // '',
        qr/!grep\s+\{\s*\$_\s*>\s*255\s*\}\s+\@octets/,
        'resolve_ctx rejects IPv4 octets above 255'
    );

    $assert->like(
        $body // '',
        qr/Invalid IPv4 format: \$input/,
        'resolve_ctx keeps invalid IPv4 reply'
    );

    $assert->like(
        $body // '',
        qr/Invalid hostname: \$input/,
        'resolve_ctx rejects malformed hostnames'
    );

    $assert->like(
        $body // '',
        qr/gethostbyname\(\$value\)/,
        'resolve_ctx still resolves valid hostnames in child process'
    );

    $assert->like(
        $body // '',
        qr/open\(\s*my \$pipe,\s*'-\|',\s*\$\^X,\s*'-e',\s*\$resolver_code,\s*\$mode,\s*\$input/s,
        'resolve_ctx still uses safe argument-list open for child perl'
    );
};
