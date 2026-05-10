# t/cases/213_contrib_icecast_http_json_guard_regression.t
# =============================================================================
# Regression checks for contrib Icecast helper robustness.
#
# The helper scripts are often used from shell/monitoring. They must not die on:
#   - HTTP::Tiny exceptions;
#   - empty responses;
#   - invalid JSON;
#   - missing icestats/source objects;
#   - out-of-range --source indexes.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_213 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    for my $script (
        File::Spec->catfile('.', 'contrib', 'icecast2', 'getIcecastListeners.pl'),
        File::Spec->catfile('.', 'contrib', 'icecast2', 'getIcecastTitle.pl'),
    ) {
        my $src = _slurp_213($script);

        $assert->like(
            $src,
            qr/eval\s+\{\s*HTTP::Tiny->new\(timeout\s*=>\s*5\)->get\(\$url\)\s*\}/,
            "$script protects HTTP::Tiny get with eval"
        );

        $assert->like(
            $src,
            qr/success\s*=>\s*0,\s*status\s*=>\s*0,\s*reason\s*=>\s*\$\@/,
            "$script has response-like fallback structure with literal \$@"
        );

        $assert->like(
            $src,
            qr/my\s+\$line\s*=\s*\$response->\{content\};/,
            "$script keeps response content in line variable"
        );

        $assert->like(
            $src,
            qr/my\s+\$json\s*=\s*eval\s+\{\s*decode_json\(\$line\)\s*\};/,
            "$script protects decode_json with eval"
        );

        $assert->like(
            $src,
            qr/ref\(\$json\)\s+ne\s+'HASH'/,
            "$script verifies decoded JSON is a HASH"
        );

        $assert->like(
            $src,
            qr/ref\(\$json->\{'icestats'\}\)\s+eq\s+'HASH'/,
            "$script verifies icestats is a HASH"
        );

        $assert->like(
            $src,
            qr/ref\(\$sources\)\s+eq\s+'ARRAY'/,
            "$script still handles multi-source ARRAY output"
        );

        $assert->like(
            $src,
            qr/\$RADIO_SOURCE\s+>\s+\$#\$sources/,
            "$script checks out-of-range source index"
        );

        $assert->like(
            $src,
            qr/Invalid --source index/,
            "$script reports invalid source index clearly"
        );

        $assert->unlike(
            $src,
            qr/my\s+\$response\s*=\s*HTTP::Tiny->new\(timeout\s*=>\s*5\)->get\(\$url\);/,
            "$script no longer calls HTTP::Tiny get without eval"
        );

        $assert->unlike(
            $src,
            qr/my\s+\$json\s*=\s*decode_json\s+\$line;/,
            "$script no longer decodes JSON without eval"
        );
    }
};
