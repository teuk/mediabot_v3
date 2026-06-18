# t/cases/112_sample_no_legacy_radio_keys.t
# =============================================================================
# Regression checks for the current mediabot.sample.conf [radio] contract.
#
# Icecast status keys and Liquidsoap queue-control keys are both active today.
# Historical single-stream keys that are no longer read must stay out of the
# public sample.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_sample_radio_contract {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _section_body_sample_radio_contract {
    my ($src, $section) = @_;
    my ($body) = $src =~ /^\[\Q$section\E\]\s*\n(.*?)(?=^\[[^\]]+\]\s*$|\z)/ms;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_sample_radio_contract(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );
    my $radio = _section_body_sample_radio_contract($sample, 'radio');

    my $admin = _slurp_sample_radio_contract(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );
    my $request = _slurp_sample_radio_contract(
        File::Spec->catfile('.', 'Mediabot', 'Radio', 'Request.pm')
    );
    my $runtime = $admin . "\n" . $request . "\n" . _slurp_sample_radio_contract(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    $assert->ok(defined $radio, 'sample config has a [radio] section');

    for my $key (
        'YOUTUBEDL_INCOMING=/tmp',
        'RADIO_DOWNLOAD_ENABLED=0',
        'YTDLP_PATH=/usr/bin/yt-dlp',
        'YTDLP_TIMEOUT=180',
        'YTDLP_REMOTE_COMPONENTS=ejs:github',
        'LIQUIDSOAP_TELNET_HOST=127.0.0.1',
        'LIQUIDSOAP_TELNET_PORT=1235',
        'LIQUIDSOAP_QUEUE_ID=mediabot_queue',
        'RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000',
        'RADIO_ICECAST_PUBLIC_BASE_URL=http://example.com:8000',
        'RADIO_ICECAST_TIMEOUT=5',
        'RADIO_ICECAST_PRIMARY_MOUNT=/radio.mp3',
    ) {
        $assert->like(
            $radio // '',
            qr/^\Q$key\E$/m,
            "sample [radio] documents current $key"
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
        )
    ) {
        $assert->unlike(
            $radio // '',
            qr/^\Q$legacy_key\E=/m,
            "sample [radio] does not define retired $legacy_key"
        );
        $assert->unlike(
            $runtime,
            qr/(?:get|_conf_value|_liquidsoap_config_value)\([^\n]*['"]\Q$legacy_key\E['"]/,
            "runtime does not read retired $legacy_key"
        );
    }

    for my $liquidsoap_key (
        qw(LIQUIDSOAP_TELNET_HOST LIQUIDSOAP_TELNET_PORT LIQUIDSOAP_QUEUE_ID)
    ) {
        $assert->like(
            $runtime,
            qr/['"]\Q$liquidsoap_key\E['"]/,
            "runtime reads current Liquidsoap key $liquidsoap_key"
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

    $assert->unlike($radio // '', qr/teuk\.org/, 'sample [radio] does not expose a private domain');
};
