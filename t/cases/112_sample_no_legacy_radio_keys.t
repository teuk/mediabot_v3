# t/cases/112_sample_no_legacy_radio_keys.t
# =============================================================================
# Regression checks for mediabot.sample.conf [radio].
#
# The official sample config should document the current Icecast radio keys.
# Old radio/liquidsoap keys are no longer read by the current Mediabot radio
# commands and should not appear as active sample configuration.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_sample_no_legacy_radio {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_sample_no_legacy_radio {
    my ($src, $section) = @_;

    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_sample_no_legacy_radio(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $radio = _section_body_sample_no_legacy_radio($sample, 'radio');

    my $runtime = _slurp_sample_no_legacy_radio(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    ) . "\n" . _slurp_sample_no_legacy_radio(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    $assert->ok(
        defined $radio,
        'sample config has a [radio] section'
    );

    for my $key (
        qw(
            YOUTUBEDL_INCOMING=/tmp
            YTDLP_PATH=/usr/bin/yt-dlp
            RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000
            RADIO_ICECAST_PUBLIC_BASE_URL=http://example.com:8000
            RADIO_ICECAST_TIMEOUT=5
            RADIO_ICECAST_PRIMARY_MOUNT=/radio160.mp3
        )
    ) {
        $assert->like(
            $radio // '',
            qr/^\Q$key\E$/m,
            "sample [radio] documents modern $key"
        );
    }

    for my $legacy_key (
        qw(
            RADIO_PORT
            RADIO_JSON
            RADIO_SOURCE
            RADIO_HOSTNAME
            RADIO_PUB
            RADIO_URL
            LIQUIDSOAP_PLAYLIST
            LIQUIDSOAP_TELNET_PORT
            LIQUIDSOAP_TELNET_HOST
        )
    ) {
        $assert->unlike(
            $radio // '',
            qr/^\Q$legacy_key\E=/m,
            "sample [radio] no longer defines legacy $legacy_key"
        );

        $assert->unlike(
            $runtime,
            qr/get\('radio\.\Q$legacy_key\E'\)/,
            "runtime does not read radio.$legacy_key"
        );
    }

    for my $runtime_key (
        qw(
            RADIO_ICECAST_STATUS_BASE_URL
            RADIO_ICECAST_PUBLIC_BASE_URL
            RADIO_ICECAST_TIMEOUT
            RADIO_ICECAST_PRIMARY_MOUNT
        )
    ) {
        $assert->like(
            $runtime,
            qr/get\('radio\.\Q$runtime_key\E'\)/,
            "runtime reads radio.$runtime_key"
        );
    }

    $assert->unlike(
        $radio // '',
        qr/teuk\.org/,
        'sample [radio] does not expose a private domain'
    );
};
