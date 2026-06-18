# t/cases/93_radio_no_private_public_url_defaults.t
# =============================================================================
# Regression checks for radio/Icecast public URL defaults.
#
# Project code must not fall back to a private deployment URL for Icecast.
# If RADIO_ICECAST_PUBLIC_BASE_URL is missing, code should use the status/base
# URL as a neutral fallback.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_radio_no_private_defaults {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my %files = (
        admin => File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm'),
        main  => File::Spec->catfile('.', 'mediabot.pl'),
    );

    for my $name (sort keys %files) {
        my $src = _slurp_radio_no_private_defaults($files{$name});

        $assert->unlike(
            $src,
            qr/RADIO_ICECAST_PUBLIC_BASE_URL'\)\s*\|\|\s*'http:\/\/teuk\.org:8000'/,
            "$files{$name} does not use a private public Icecast fallback"
        );

        $assert->unlike(
            $src,
            qr/http:\/\/teuk\.org:8000\/radio160\.mp3/,
            "$files{$name} does not use a private song listen URL fallback"
        );

        $assert->like(
            $src,
            qr/my\s+\$public_base\s*=\s*\$conf->get\('radio\.RADIO_ICECAST_PUBLIC_BASE_URL'\)\s*\|\|\s*\$base_url;/,
            "$files{$name} falls back public_base to base_url"
        );
    }

    my $admin = _slurp_radio_no_private_defaults(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    $assert->like(
        $admin,
        qr/my\s+\$listen_url\s*=\s*\$info->\{listen_url\}\s*\|\|\s*\(\$public_base\s*\.\s*\$primary_mount\);/,
        'song fallback listen URL is built from public_base and primary_mount'
    );

    my $sample = _slurp_radio_no_private_defaults(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    $assert->like(
        $sample,
        qr/RADIO_ICECAST_PUBLIC_BASE_URL=http:\/\/example\.com:8000/,
        'sample config uses example.com for public Icecast URL'
    );

    $assert->unlike(
        $sample,
        qr/RADIO_ICECAST_PUBLIC_BASE_URL=http:\/\/teuk\.org:8000/,
        'sample config does not expose a private Icecast public URL'
    );
};
