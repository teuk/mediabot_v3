# t/cases/92_radio_sample_conf_icecast_keys.t
# =============================================================================
# Regression checks for sample configuration files.
#
# The official sample config must live at the repository root only:
#   mediabot.sample.conf
#
# The radio/Icecast commands use RADIO_ICECAST_* keys. The root sample config
# must expose them so new installs do not silently fall back to private or
# project-specific defaults.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Find;
use File::Spec;

sub _slurp_radio_sample_conf {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _find_sample_configs_radio {
    my @files;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless $File::Find::name =~ /(?:^|\/)mediabot\.sample\.conf\z/;
                push @files, $File::Find::name;
            },
        },
        '.'
    );

    return sort @files;
}

return sub {
    my ($assert) = @_;

    my $root_sample = File::Spec->catfile('.', 'mediabot.sample.conf');
    my @samples     = _find_sample_configs_radio();

    $assert->is(
        join(', ', @samples),
        './mediabot.sample.conf',
        'only the root sample config exists'
    );

    $assert->ok(
        -f $root_sample,
        'official sample config exists at repository root'
    );

    my $src = _slurp_radio_sample_conf($root_sample);

    $assert->like(
        $src,
        qr/^\[radio\]$/m,
        'root sample config has a [radio] section'
    );

    for my $key (
        qw(
            RADIO_ICECAST_STATUS_BASE_URL
            RADIO_ICECAST_PUBLIC_BASE_URL
            RADIO_ICECAST_TIMEOUT
            RADIO_ICECAST_PRIMARY_MOUNT
        )
    ) {
        $assert->like(
            $src,
            qr/^\Q$key\E=/m,
            "root sample config documents $key"
        );
    }

    $assert->like(
        $src,
        qr/^RADIO_ICECAST_STATUS_BASE_URL=http:\/\/127\.0\.0\.1:8000$/m,
        'root sample defaults Icecast status URL to local host'
    );

    $assert->like(
        $src,
        qr/^RADIO_ICECAST_PUBLIC_BASE_URL=http:\/\/example\.com:8000$/m,
        'root sample uses example.com for public Icecast sample URL'
    );

    $assert->unlike(
        $src,
        qr/^RADIO_ICECAST_PUBLIC_BASE_URL=http:\/\/teuk\.org:8000$/m,
        'root sample does not expose a private public URL'
    );
};
