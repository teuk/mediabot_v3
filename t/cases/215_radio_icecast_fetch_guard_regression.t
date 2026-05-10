# t/cases/215_radio_icecast_fetch_guard_regression.t
# =============================================================================
# Regression checks for Mediabot::Radio::Icecast::_fetch_icestats().
#
# Icecast runtime status fetches should:
#   - wrap HTTP calls with eval and a response-like fallback hash;
#   - reject empty content before JSON decoding;
#   - decode the checked content variable, not res->{content} directly.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_215 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_215 {
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

    my $src = _slurp_215(
        File::Spec->catfile('.', 'Mediabot', 'Radio', 'Icecast.pm')
    );

    my $body = _extract_sub_215($src, '_fetch_icestats');

    $assert->ok(
        defined $body && $body ne '',
        '_fetch_icestats body found'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$res\s*=\s*eval\s+\{\s*\$self->\{ua\}->get\(\$url\)\s*\}/,
        '_fetch_icestats protects HTTP get with eval'
    );

    $assert->like(
        $body // '',
        qr/reason\s*=>\s*\$\@/,
        '_fetch_icestats uses response-like fallback with literal $@'
    );

    $assert->like(
        $body // '',
        qr/my\s+\$content\s*=\s*\$res->\{content\}\s*\/\/\s*'';/,
        '_fetch_icestats stores response content safely'
    );

    $assert->like(
        $body // '',
        qr/unless\s+\(\$content\s+ne\s+''\)/,
        '_fetch_icestats rejects empty content before JSON decode'
    );

    $assert->like(
        $body // '',
        qr/Icecast empty response for \$url/,
        '_fetch_icestats logs empty Icecast response'
    );

    $assert->like(
        $body // '',
        qr/decode_json\(\$content\)/,
        '_fetch_icestats decodes checked content variable'
    );

    $assert->unlike(
        $body // '',
        qr/decode_json\(\$res->\{content\}\)/,
        '_fetch_icestats no longer decodes res content directly'
    );
};
