# t/cases/137_contrib_icecast_no_curl_pipe.t
# =============================================================================
# Regression checks for contrib Icecast helper scripts.
#
# The helpers should not fetch Icecast JSON through a shell curl pipeline.
# HTTP::Tiny is enough here and avoids shell interpolation of host/port/path.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_contrib_icecast_no_curl {
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
        my $src = _slurp_contrib_icecast_no_curl($script);

        $assert->like(
            $src,
            qr/^use HTTP::Tiny;$/m,
            "$script imports HTTP::Tiny"
        );

        $assert->like(
            $src,
            qr/my \$url = "http:\/\/\$RADIO_HOSTNAME:\$RADIO_PORT\/\$RADIO_JSON";/,
            "$script builds the Icecast status URL explicitly"
        );

        $assert->like(
            $src,
            qr/HTTP::Tiny->new\(timeout => 5\)->get\(\$url\)/,
            "$script fetches Icecast JSON through HTTP::Tiny"
        );

        $assert->like(
            $src,
            qr/my \$line = \$response->\{content\};/,
            "$script decodes JSON from HTTP response content"
        );

        $assert->unlike(
            $src,
            qr/open\s+ICECAST_STATUS_JSON/,
            "$script no longer opens a curl pipe"
        );

        $assert->unlike(
            $src,
            qr/curl -f -s/,
            "$script no longer shells out to curl"
        );

        $assert->unlike(
            $src,
            qr/<ICECAST_STATUS_JSON>/,
            "$script no longer reads from a command pipe handle"
        );

        $assert->like(
            $src,
            qr/"source=i"\s*=>\s*\\\$RADIO_SOURCE/,
            "$script still accepts --source"
        );
    }
};
