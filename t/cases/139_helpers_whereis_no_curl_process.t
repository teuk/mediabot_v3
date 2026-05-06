# t/cases/139_helpers_whereis_no_curl_process.t
# =============================================================================
# Regression checks for Mediabot::Helpers::whereis().
#
# whereis() should not spawn curl for a simple country.is HTTP request.
# HTTP::Tiny is enough and keeps the helper portable and easier to test.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_helpers_whereis {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_helpers_whereis {
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

    my $src = _slurp_helpers_whereis(
        File::Spec->catfile('.', 'Mediabot', 'Helpers.pm')
    );

    my $body = _extract_sub_body_helpers_whereis($src, 'whereis');

    $assert->ok(
        defined $body,
        'whereis body found'
    );

    $assert->like(
        $src,
        qr/^use HTTP::Tiny;$/m,
        'Helpers.pm imports HTTP::Tiny'
    );

    $assert->like(
        $body // '',
        qr/my \$whereis_url = "https:\/\/api\.country\.is\/\$userIP";/,
        'whereis builds the country.is URL from the resolved IP'
    );

    $assert->like(
        $body // '',
        qr/HTTP::Tiny->new\(timeout => 3\)->get\(\$whereis_url\)/,
        'whereis fetches country.is with HTTP::Tiny and a short timeout'
    );

    $assert->like(
        $body // '',
        qr/return "N\/A" unless \$response->\{success\};/,
        'whereis returns N/A on HTTP failure'
    );

    $assert->like(
        $body // '',
        qr/my \$line = \$response->\{content\} \/\/ '';/,
        'whereis reads JSON from HTTP response content'
    );

    $assert->like(
        $body // '',
        qr/ref\(\$json\) ne 'HASH'/,
        'whereis validates decoded JSON is a HASH'
    );

    $assert->unlike(
        $body // '',
        qr/open\s+\$fh_whereis/,
        'whereis no longer opens a curl process'
    );

    $assert->unlike(
        $body // '',
        qr/curl/,
        'whereis body no longer mentions curl'
    );

    $assert->unlike(
        $body // '',
        qr/<\$fh_whereis>/,
        'whereis no longer reads from a command pipe'
    );
};
