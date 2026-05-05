# t/cases/107_live_template_radio_icecast_keys.t
# =============================================================================
# Regression checks for t/live/test.conf.tpl radio configuration.
#
# The live test template may keep old radio keys for compatibility, but it must
# also include the modern RADIO_ICECAST_* keys used by current radio commands.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_live_radio_template {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $tpl = _slurp_live_radio_template(
        File::Spec->catfile('.', 't', 'live', 'test.conf.tpl')
    );

    my $admin = _slurp_live_radio_template(
        File::Spec->catfile('.', 'Mediabot', 'AdminCommands.pm')
    );

    my $main = _slurp_live_radio_template(
        File::Spec->catfile('.', 'mediabot.pl')
    );

    $assert->like(
        $tpl,
        qr/^\[radio\]$/m,
        'live template has a [radio] section'
    );

    for my $key (
        qw(
            RADIO_ICECAST_STATUS_BASE_URL=http://127.0.0.1:8000
            RADIO_ICECAST_PUBLIC_BASE_URL=http://127.0.0.1:8000
            RADIO_ICECAST_TIMEOUT=5
            RADIO_ICECAST_PRIMARY_MOUNT=/radio160.mp3
        )
    ) {
        $assert->like(
            $tpl,
            qr/^\Q$key\E$/m,
            "live template contains $key"
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
            $admin . "\n" . $main,
            qr/get\('radio\.\Q$runtime_key\E'\)/,
            "runtime reads radio.$runtime_key"
        );
    }

    $assert->unlike(
        $tpl,
        qr/teuk\.org/,
        'live radio template does not use private public URLs'
    );
};
